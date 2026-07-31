-- | Handlers.
--
-- @ReaderT Env Handler@ hoisted into servant. No effect system: there are two
-- pieces of context and they never change.
module Quiz.Server
  ( Env (..)
  , app
  ) where

import Control.Monad (unless)
import Control.Monad.Reader
import Data.Aeson (Value, object, toJSON, (.=))
import Data.ByteString.Lazy qualified as BL
import Data.List (find, sortOn)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Time (NominalDiffTime, getCurrentTime)
import Lucid (Html)
import Network.Wai (Middleware, mapResponseHeaders, pathInfo)
import Servant

import Quiz.Answer
import Quiz.Server.Api
import Quiz.Server.Html
import Quiz.Store
import Quiz.Token
import Quiz.Types
import Quiz.Validate (formatProblem, validateQuiz)

data Env = Env
  { envStore :: Store
  , envAdminToken :: Text
  , envSigningKey :: SigningKey
  , envTokenMaxAge :: NominalDiffTime
  , -- | Public origin, for the one page that must print a URL students can
    -- type. Empty when unconfigured.
    envBaseUrl :: Text
  }

type AppM = ReaderT Env Handler

app :: Env -> Application
app env =
  allowEmbedCors $ serve api (hoistServer api (\a -> runReaderT a env) server)
  where
    api = Proxy @API

-- | Let a deck hosted anywhere read the embed endpoints with @fetch@.
--
-- Scoped to @/embed@ deliberately: those responses are already public and
-- unauthenticated — anyone with the URL can open them in a browser — so
-- allowing a script to read what a person could read anyway grants nothing
-- new. The admin API is left alone.
--
-- No @OPTIONS@ handling is needed: a plain @GET@ with no custom headers is a
-- CORS \"simple request\" and is never preflighted.
allowEmbedCors :: Middleware
allowEmbedCors downstream request respond
  | isEmbed = downstream request (respond . mapResponseHeaders (header :))
  | otherwise = downstream request respond
  where
    isEmbed = case pathInfo request of
      ("embed" : _) -> True
      _ -> False
    header = ("Access-Control-Allow-Origin", "*")

server :: ServerT API AppM
server =
  studentRoutes
    :<|> embedRoutes
    :<|> presenterRoutes
    :<|> adminRoutes
    :<|> pure "ok"

-- Student -------------------------------------------------------------------

studentRoutes :: Text -> ServerT StudentSub AppM
studentRoutes code =
  indexH code
    :<|> questionH code
    :<|> submitH code
    :<|> doneH code

-- | Resolve the join code against the single active session.
withSession :: Text -> (SessionState -> AppM a) -> AppM a -> AppM a
withSession code k fallback = do
  world <- liftIO . readWorld =<< asks envStore
  case activeState world of
    Just st | unJoinCode (sessionCode (stateSession st)) == T.toUpper code -> k st
    _ -> fallback

indexH :: Text -> AppM (Html ())
indexH code = withSession code render (pure studentNoSession)
  where
    render st =
      pure $
        studentIndex
          (sessionCode (stateSession st))
          (stateQuiz st)
          [(q, phaseOf (questionKey q) st) | q <- quizQuestions (stateQuiz st)]

questionH :: Text -> Text -> Maybe Text -> AppM (Html ())
questionH code qkeyRaw mErr = withSession code render (pure studentNoSession)
  where
    qkey = QuestionKey qkeyRaw
    render st = case findQuestion qkey st of
      Just question | phaseOf qkey st == Live -> do
        env <- ask
        now <- liftIO getCurrentTime
        let token =
              mintToken
                (envSigningKey env)
                now
                (unSessionId (sessionId (stateSession st)))
                qkeyRaw
        pure (questionForm (sessionCode (stateSession st)) question token mErr)
      -- Closed, revealed, or not yet opened: send them back to the list rather
      -- than showing a form that cannot be submitted.
      _ -> indexH code

submitH :: Text -> Text -> SubmitForm -> AppM Redirect
submitH code qkeyRaw form = withSession code submit notRunning
  where
    qkey = QuestionKey qkeyRaw
    notRunning = pure (redirectTo ("/s/" <> code))

    submit st = case findQuestion qkey st of
      Nothing -> pure (redirectTo ("/s/" <> code))
      Just question -> do
        env <- ask
        now <- liftIO getCurrentTime
        let sid = unSessionId (sessionId (stateSession st))
            outcome = do
              case
                checkToken
                  (envSigningKey env)
                  (envTokenMaxAge env)
                  now
                  sid
                  qkeyRaw
                  (FormToken (submitToken form))
                of
                  Left e -> Left (describeTokenError e)
                  Right () -> Right ()
              answerFromForm (questionBody question) form
        case outcome of
          Left err -> pure (rejected err)
          Right answer -> do
            recorded <-
              liftIO $
                recordResponse
                  (envStore env)
                  now
                  (sessionId (stateSession st))
                  qkey
                  answer
            case recorded of
              Left err -> pure (rejected err)
              Right _ -> pure (redirectTo (donePath answer))

    donePath answer =
      "/s/" <> code <> "/" <> qkeyRaw <> "/done" <> case answer of
        AnswerChoice k -> "?a=" <> unOptionKey k
        _ -> ""
    rejected err =
      redirectTo ("/s/" <> code <> "/" <> qkeyRaw <> "?e=" <> escape err)

doneH :: Text -> Text -> Maybe Text -> AppM (Html ())
doneH code qkeyRaw mChosen = withSession code render (pure studentNoSession)
  where
    qkey = QuestionKey qkeyRaw
    render st = case findQuestion qkey st of
      Nothing -> indexH code
      Just question ->
        pure $
          donePage
            (sessionCode (stateSession st))
            question
            (verdict (stateQuiz st) question)
      where
        verdict quiz q = do
          -- Only "immediate" discloses before the presenter closes the
          -- question; every other mode stays silent here.
          case quizFeedback quiz of
            FeedbackImmediate -> pure ()
            _ -> Nothing
          chosen <- mChosen
          correct <- case questionBody q of
            BodyChoice spec -> choiceCorrect spec
            _ -> Nothing
          pure (OptionKey chosen == correct)

-- Embed ---------------------------------------------------------------------

embedRoutes :: Text -> ServerT EmbedSub AppM
embedRoutes slug = joinH slug :<|> joinFragH slug :<|> fragH slug :<|> resultsH slug

joinFragH :: Text -> AppM (Html ())
joinFragH slug = do
  world <- liftIO . readWorld =<< asks envStore
  base <- asks envBaseUrl
  pure $ case activeState world of
    Just st
      | unQuizSlug (sessionQuizSlug (stateSession st)) == slug ->
          joinFragment base (sessionCode (stateSession st))
    _ -> fragmentNotLive

-- | Both embeds resolve the active session themselves, and both must be loud
-- when the slide's quiz is not the one that is live.
withActiveQuiz :: Text -> (SessionState -> AppM (Html ())) -> AppM (Html ())
withActiveQuiz slug k = do
  world <- liftIO . readWorld =<< asks envStore
  case activeState world of
    Just st | unQuizSlug (sessionQuizSlug (stateSession st)) == slug -> k st
    _ -> pure (embedNotLive slug)

joinH :: Text -> AppM (Html ())
joinH slug = withActiveQuiz slug $ \st -> do
  base <- asks envBaseUrl
  pure (embedJoin base (Just (stateQuiz st, sessionCode (stateSession st))))

-- | Bare rows for a deck to inject. Deliberately answers 200 with a "not live"
-- row rather than 404: the deck polls this every couple of seconds, and a
-- stream of console errors during a lecture helps nobody.
fragH :: Text -> Text -> AppM (Html ())
fragH slug qkeyRaw = do
  world <- liftIO . readWorld =<< asks envStore
  pure $ case activeState world of
    Just st
      | unQuizSlug (sessionQuizSlug (stateSession st)) == slug
      , Just question <- findQuestion (QuestionKey qkeyRaw) st ->
          embedFragment
            question
            (phaseOf (QuestionKey qkeyRaw) st)
            (tallyFor question (responsesFor (QuestionKey qkeyRaw) st))
    _ -> fragmentNotLive

resultsH :: Text -> Text -> AppM (Html ())
resultsH slug qkeyRaw = withActiveQuiz slug $ \st ->
  case findQuestion (QuestionKey qkeyRaw) st of
    Nothing -> pure (embedNotLive slug)
    Just question ->
      pure $
        embedResults
          question
          (phaseOf (QuestionKey qkeyRaw) st)
          (tallyFor question (responsesFor (QuestionKey qkeyRaw) st))

-- Presenter ------------------------------------------------------------------

presenterRoutes :: Text -> ServerT PresenterSub AppM
presenterRoutes secret =
  pageH :<|> activateH :<|> textH :<|> phaseActionH
  where
    -- Wrong secrets get a bare 404 with no hint that the path space exists.
    withPresenter :: (SessionState -> Bool -> AppM a) -> AppM a
    withPresenter k = do
      world <- liftIO . readWorld =<< asks envStore
      case sessionBySecret (Secret secret) world of
        Nothing -> throwError err404{errBody = "not found\n"}
        Just st ->
          k st (worldActive world == Just (sessionId (stateSession st)))

    back :: AppM Redirect
    back = pure (redirectTo ("/p/" <> secret))

    pageH = withPresenter $ \st isActive ->
      pure (presenterPage (Secret secret) isActive st)

    activateH = withPresenter $ \st _ -> do
      store <- asks envStore
      _ <- orFail =<< liftIO (activateSession store (sessionId (stateSession st)))
      back

    textH rid action = withPresenter $ \st _ -> do
      visible <- case action of
        "show" -> pure True
        "hide" -> pure False
        _ -> throwError err404{errBody = "not found\n"}
      store <- asks envStore
      orFail
        =<< liftIO
          (setTextVisible store (sessionId (stateSession st)) (ResponseId rid) visible)
      back

    phaseActionH action qkey = withPresenter $ \st _ -> do
      phase <- case action of
        "open" -> pure Live
        "close" -> pure Closed
        "reveal" -> pure Revealed
        _ -> throwError err404{errBody = "not found\n"}
      store <- asks envStore
      orFail
        =<< liftIO
          (setPhase store (sessionId (stateSession st)) (QuestionKey qkey) phase)
      back

-- Admin ---------------------------------------------------------------------

adminRoutes :: ServerT AdminAPI AppM
adminRoutes =
  pushH :<|> newSessionH :<|> phaseH :<|> stateH :<|> sessionsH :<|> logH :<|> clearH

requireAuth :: Maybe Text -> AppM ()
requireAuth given = do
  expected <- asks envAdminToken
  let ok = case given of
        Just header -> T.stripPrefix "Bearer " header == Just expected
        Nothing -> False
  unless ok . throwError $
    err401{errBody = "missing or invalid bearer token\n"}

pushH :: Maybe Text -> Quiz -> AppM Value
pushH auth quiz = do
  requireAuth auth
  case validateQuiz quiz of
    [] -> pure ()
    problems ->
      throwError
        err400
          { errBody =
              encodeUtf8Lazy $
                "quiz has problems:\n"
                  <> T.unlines (map (("  " <>) . formatProblem) problems)
          }
  store <- asks envStore
  now <- liftIO getCurrentTime
  orFail =<< liftIO (pushQuiz store now quiz)
  pure $
    object
      [ "quiz" .= unQuizSlug (quizSlug quiz)
      , "questions" .= length (quizQuestions quiz)
      ]

newSessionH :: Maybe Text -> NewSession -> AppM Value
newSessionH auth request = do
  requireAuth auth
  store <- asks envStore
  now <- liftIO getCurrentTime
  session <-
    liftIO $
      freshSession now (QuizSlug (newSessionQuiz request)) (newSessionLabel request)
  orFail =<< liftIO (createSession store session)
  pure (toJSON session)

phaseH :: Maybe Text -> PhaseChange -> AppM Value
phaseH auth change = do
  requireAuth auth
  store <- asks envStore
  world <- liftIO (readWorld store)
  case activeState world of
    Nothing -> throwError err409{errBody = "no active session\n"}
    Just st -> do
      orFail
        =<< liftIO
          ( setPhase
              store
              (sessionId (stateSession st))
              (QuestionKey (phaseQuestion change))
              (phaseTo change)
          )
      pure $
        object
          ["question" .= phaseQuestion change, "phase" .= phaseTo change]

stateH :: Maybe Text -> AppM Value
stateH auth = do
  requireAuth auth
  world <- liftIO . readWorld =<< asks envStore
  case activeState world of
    Nothing -> pure (object ["active" .= False])
    Just st ->
      pure $
        object
          [ "active" .= True
          , "session" .= toJSON (stateSession st)
          , "questions"
              .= [ object
                    [ "key" .= unQuestionKey (questionKey q)
                    , "prompt" .= questionPrompt q
                    , "type" .= questionTypeName (questionBody q)
                    , "phase" .= phaseOf (questionKey q) st
                    , "responses" .= length (responsesFor (questionKey q) st)
                    ]
                 | q <- quizQuestions (stateQuiz st)
                 ]
          ]

-- | Every session, newest first, each with the presenter secret needed to
-- reach its controls again.
sessionsH :: Maybe Text -> AppM Value
sessionsH auth = do
  requireAuth auth
  world <- liftIO . readWorld =<< asks envStore
  base <- asks envBaseUrl
  let newestFirst =
        sortOn (Down . sessionCreatedAt . stateSession) (Map.elems (worldSessions world))
      describe st =
        let s = stateSession st
         in object
              [ "id" .= unSessionId (sessionId s)
              , "code" .= unJoinCode (sessionCode s)
              , "secret" .= unSecret (sessionSecret s)
              , "quiz" .= unQuizSlug (sessionQuizSlug s)
              , "label" .= sessionLabel s
              , "created_at" .= sessionCreatedAt s
              , "active" .= (worldActive world == Just (sessionId s))
              , "responses" .= length (stateResponses st)
              ]
  pure $ object ["base_url" .= base, "sessions" .= map describe newestFirst]

-- | The response log, verbatim. The storage format is the export format, so
-- there is nothing to serialise here.
logH :: Maybe Text -> AppM Text
logH auth = do
  requireAuth auth
  store <- asks envStore
  case storeLogPath store of
    Nothing -> pure ""
    Just path -> liftIO (TIO.readFile path)

-- | Delete everything. See 'clearAll'; the confirmation belongs to the CLI,
-- which knows whether a human is watching.
clearH :: Maybe Text -> AppM Value
clearH auth = do
  requireAuth auth
  store <- asks envStore
  report <- liftIO (clearAll store)
  pure $
    object
      [ "quizzes" .= clearedQuizzes report
      , "sessions" .= clearedSessions report
      , "responses" .= clearedResponses report
      ]

-- Helpers -------------------------------------------------------------------

findQuestion :: QuestionKey -> SessionState -> Maybe Question
findQuestion qkey = find ((== qkey) . questionKey) . quizQuestions . stateQuiz

orFail :: Either Text a -> AppM a
orFail = \case
  Left err -> throwError err400{errBody = encodeUtf8Lazy (err <> "\n")}
  Right a -> pure a

redirectTo :: Text -> Redirect
redirectTo location = addHeader location NoContent

-- | Percent-encode the few characters that would break a query string. The
-- messages are our own, so this does not need to be a general encoder.
escape :: Text -> Text
escape = T.concatMap $ \c -> case c of
  ' ' -> "+"
  '&' -> "%26"
  '#' -> "%23"
  '?' -> "%3F"
  '%' -> "%25"
  '+' -> "%2B"
  _ -> T.singleton c

encodeUtf8Lazy :: Text -> BL.ByteString
encodeUtf8Lazy = BL.fromStrict . TE.encodeUtf8
