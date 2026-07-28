-- | In-memory state, backed by an append-only event log.
--
-- There is no database. Live state is a 'World' behind a 'TVar'; every change
-- is expressed as an 'Event' which is applied to that value and appended to a
-- JSONL file. State transitions exist only in 'applyEvent', so replaying the
-- log necessarily reproduces the state that produced it.
--
-- The log's job is not archival durability — see DESIGN.md — it is to survive a
-- machine auto-stopping mid-lecture, since Fly retains a rootfs across
-- stop/start. It is also the export format: @quizctl pull@ just fetches it.
module Quiz.Store
  ( -- * Identifiers
    SessionId (..)
  , JoinCode (..)
  , Secret (..)
  , ResponseId (..)
  , Phase (..)

    -- * State
  , Session (..)
  , SessionState (..)
  , World (..)
  , Response (..)
  , emptyWorld

    -- * Events
  , Event (..)
  , applyEvent

    -- * Store
  , Store
  , ReplayReport (..)
  , openStore
  , storeLogPath
  , readWorld
  , activeState
  , sessionBySecret

    -- * Operations
  , pushQuiz
  , freshSession
  , createSession
  , activateSession
  , setPhase
  , recordResponse
  , setTextVisible

    -- * Reading
  , phaseOf
  , responsesFor
  , Tally (..)
  , tallyFor
  ) where

import Control.Concurrent.MVar
import Control.Concurrent.STM
import Data.Aeson
import Data.Aeson.Types (Parser)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy.Char8 qualified as BLC
import Data.List (find, sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath (takeDirectory)
import System.IO

import Quiz.Answer

-- For the ToJSON/FromJSON Quiz instances: a pushed quiz is stored in the event
-- log, and read back from it on replay.
import Quiz.Parse ()
import Quiz.Types

newtype SessionId = SessionId {unSessionId :: Text}
  deriving stock (Eq, Ord, Show)

-- | Short, unambiguous, announced in the room.
newtype JoinCode = JoinCode {unJoinCode :: Text}
  deriving stock (Eq, Ord, Show)

-- | Unguessable; the presenter page lives at this path. Never project it.
newtype Secret = Secret {unSecret :: Text}
  deriving stock (Eq, Ord, Show)

newtype ResponseId = ResponseId {unResponseId :: Int}
  deriving stock (Eq, Ord, Show)

data Phase
  = -- | Not yet shown; answers refused.
    Pending
  | -- | Accepting answers.
    Live
  | -- | Closed; tallies shown, answers refused.
    Closed
  | -- | Closed, and correct answers disclosed.
    Revealed
  deriving stock (Eq, Show)

data Session = Session
  { sessionId :: SessionId
  , sessionCode :: JoinCode
  , sessionSecret :: Secret
  , sessionQuizSlug :: QuizSlug
  , sessionLabel :: Text
  , sessionCreatedAt :: UTCTime
  }
  deriving stock (Eq, Show)

data Response = Response
  { responseId :: ResponseId
  , responseQuestion :: QuestionKey
  , responseAnswer :: Answer
  , responseAt :: UTCTime
  , -- | Free text starts hidden and must be promoted by the presenter.
    responseVisible :: Bool
  }
  deriving stock (Eq, Show)

data SessionState = SessionState
  { stateSession :: Session
  , -- | The quiz as it was when the session was created, so editing the YAML
    -- later cannot change what a past session asked.
    stateQuiz :: Quiz
  , statePhases :: Map QuestionKey Phase
  , -- | Newest first.
    stateResponses :: [Response]
  }
  deriving stock (Eq, Show)

data World = World
  { worldQuizzes :: Map QuizSlug Quiz
  , worldSessions :: Map SessionId SessionState
  , -- | Exactly one session is live server-wide.
    worldActive :: Maybe SessionId
  , worldNextResponse :: Int
  }
  deriving stock (Eq, Show)

emptyWorld :: World
emptyWorld =
  World
    { worldQuizzes = Map.empty
    , worldSessions = Map.empty
    , worldActive = Nothing
    , worldNextResponse = 1
    }

-- Events --------------------------------------------------------------------

data Event
  = QuizPushed UTCTime Quiz
  | SessionCreated Session
  | SessionActivated SessionId
  | PhaseSet SessionId QuestionKey Phase
  | ResponseRecorded SessionId Response
  | TextVisibilitySet SessionId ResponseId Bool
  deriving stock (Eq, Show)

-- | The only place state changes. Replay and live updates share it, so they
-- cannot drift apart.
applyEvent :: Event -> World -> World
applyEvent ev w = case ev of
  QuizPushed _ quiz ->
    w{worldQuizzes = Map.insert (quizSlug quiz) quiz (worldQuizzes w)}
  SessionCreated session ->
    let quiz =
          fromMaybe
            (placeholderQuiz (sessionQuizSlug session))
            (Map.lookup (sessionQuizSlug session) (worldQuizzes w))
        st =
          SessionState
            { stateSession = session
            , stateQuiz = quiz
            , statePhases = Map.empty
            , stateResponses = []
            }
     in w{worldSessions = Map.insert (sessionId session) st (worldSessions w)}
  SessionActivated sid ->
    w{worldActive = Just sid}
  PhaseSet sid qkey phase ->
    overSession sid (\st -> st{statePhases = Map.insert qkey phase (statePhases st)}) w
  ResponseRecorded sid response ->
    let bumped = max (worldNextResponse w) (unResponseId (responseId response) + 1)
     in (overSession sid (\st -> st{stateResponses = response : stateResponses st}) w)
          {worldNextResponse = bumped}
  TextVisibilitySet sid rid visible ->
    overSession
      sid
      ( \st ->
          st
            { stateResponses =
                map
                  (\r -> if responseId r == rid then r{responseVisible = visible} else r)
                  (stateResponses st)
            }
      )
      w
  where
    overSession sid f world =
      world{worldSessions = Map.adjust f sid (worldSessions world)}

-- | A session can only be created for a quiz that has been pushed, so this is
-- unreachable in practice; it exists so that replaying a truncated log cannot
-- crash the server on boot.
placeholderQuiz :: QuizSlug -> Quiz
placeholderQuiz slug =
  Quiz
    { quizSlug = slug
    , quizTitle = unQuizSlug slug
    , quizFeedback = FeedbackNone
    , quizQuestions = []
    }

-- Store ---------------------------------------------------------------------

data Store = Store
  { storeWorld :: TVar World
  , -- | Serialises appends. Deliberately not a held-open 'Handle': GHC locks a
    -- file per process, so keeping the log open in AppendMode makes reading it
    -- back fail with @resource busy@ — which would break @GET /api/log@, and
    -- so @quizctl pull@, the one operation that must never fail. Reopening per
    -- append costs microseconds at a few hundred writes per lecture.
    storeLogLock :: Maybe (MVar ())
  , storeLogPath :: Maybe FilePath
  }

data ReplayReport = ReplayReport
  { replayedEvents :: Int
  , replaySkipped :: Int
  }
  deriving stock (Eq, Show)

-- | Open the store, replaying any existing log first. Pass 'Nothing' to run
-- entirely in memory (used by tests).
openStore :: Maybe FilePath -> IO (Store, ReplayReport)
openStore Nothing = do
  var <- newTVarIO emptyWorld
  pure (Store var Nothing Nothing, ReplayReport 0 0)
openStore (Just path) = do
  createDirectoryIfMissing True (takeDirectory path)
  exists <- doesFileExist path
  (world, report) <-
    if exists
      then replayFile path
      else pure (emptyWorld, ReplayReport 0 0)
  var <- newTVarIO world
  lock <- newMVar ()
  pure (Store var (Just lock) (Just path), report)

replayFile :: FilePath -> IO (World, ReplayReport)
replayFile path = do
  contents <- BLC.fromStrict <$> BS.readFile path
  let step (w, ok, bad) line
        | BLC.null (BLC.dropWhile (== ' ') line) = (w, ok, bad)
        | otherwise = case decode line of
            Just ev -> (applyEvent ev w, ok + 1, bad)
            Nothing -> (w, ok, bad + 1)
      (world, good, skipped) = foldl' step (emptyWorld, 0, 0) (BLC.lines contents)
  pure (world, ReplayReport good skipped)

readWorld :: Store -> IO World
readWorld = readTVarIO . storeWorld

-- | The live session, if any.
activeState :: World -> Maybe SessionState
activeState w = do
  sid <- worldActive w
  Map.lookup sid (worldSessions w)

-- | Resolve a presenter secret to its session — any session, not just the
-- active one, since the presenter page for a superseded session must still
-- load (that is how it gets reactivated). A linear scan: a semester produces
-- a few dozen sessions at most.
sessionBySecret :: Secret -> World -> Maybe SessionState
sessionBySecret secret =
  find ((== secret) . sessionSecret . stateSession) . Map.elems . worldSessions

-- | Apply a change: derive events from the current world, commit them
-- atomically, then append.
--
-- The append happens after the commit, so a crash in between loses the event.
-- Given that the log exists to survive an auto-stop rather than to be an
-- archive, that is an acceptable trade for not holding a lock across IO.
apply :: Store -> (World -> Either Text ([Event], a)) -> IO (Either Text a)
apply store derive = do
  outcome <- atomically $ do
    w <- readTVar (storeWorld store)
    case derive w of
      Left err -> pure (Left err)
      Right (events, a) -> do
        writeTVar (storeWorld store) (foldl' (flip applyEvent) w events)
        pure (Right (events, a))
  case outcome of
    Left err -> pure (Left err)
    Right (events, a) -> do
      mapM_ (append store) events
      pure (Right a)

append :: Store -> Event -> IO ()
append store event = case (storeLogLock store, storeLogPath store) of
  (Just lock, Just path) -> withMVar lock $ \() ->
    -- Written as bytes, so the log is UTF-8 regardless of the process locale.
    withFile path AppendMode $ \h -> BLC.hPutStrLn h (encode event)
  _ -> pure ()

-- Operations ----------------------------------------------------------------

pushQuiz :: Store -> UTCTime -> Quiz -> IO (Either Text ())
pushQuiz store now quiz = apply store $ \_ -> Right ([QuizPushed now quiz], ())

-- | Build a session with fresh random identifiers. Separate from
-- 'createSession' so that the identifiers appear in the event log rather than
-- being regenerated on replay.
freshSession :: UTCTime -> QuizSlug -> Text -> IO Session
freshSession now slug label = do
  sid <- randomHex 8
  code <- randomCode 5
  secret <- randomHex 32
  pure
    Session
      { sessionId = SessionId sid
      , sessionCode = JoinCode code
      , sessionSecret = Secret secret
      , sessionQuizSlug = slug
      , sessionLabel = label
      , sessionCreatedAt = now
      }

-- | Creates the session and makes it the active one, since there is no reason
-- to create one and not use it.
createSession :: Store -> Session -> IO (Either Text ())
createSession store session = apply store $ \w ->
  if Map.member (sessionQuizSlug session) (worldQuizzes w)
    then Right ([SessionCreated session, SessionActivated (sessionId session)], ())
    else
      Left $
        "no quiz '"
          <> unQuizSlug (sessionQuizSlug session)
          <> "' has been pushed"

activateSession :: Store -> SessionId -> IO (Either Text Session)
activateSession store sid = apply store $ \w ->
  case Map.lookup sid (worldSessions w) of
    Nothing -> Left ("no session " <> unSessionId sid)
    Just st -> Right ([SessionActivated sid], stateSession st)

setPhase :: Store -> SessionId -> QuestionKey -> Phase -> IO (Either Text ())
setPhase store sid qkey phase = apply store $ \w ->
  case Map.lookup sid (worldSessions w) of
    Nothing -> Left ("no session " <> unSessionId sid)
    Just st
      | any ((== qkey) . questionKey) (quizQuestions (stateQuiz st)) ->
          Right ([PhaseSet sid qkey phase], ())
      | otherwise -> Left ("no question '" <> unQuestionKey qkey <> "' in this quiz")

-- | Records an answer, validating it against the question and refusing unless
-- the question is currently open.
recordResponse
  :: Store
  -> UTCTime
  -> SessionId
  -> QuestionKey
  -> Answer
  -> IO (Either Text ResponseId)
recordResponse store now sid qkey answer = apply store $ \w -> do
  st <- maybe (Left "that session is not running") Right (Map.lookup sid (worldSessions w))
  question <-
    maybe (Left "no such question") Right $
      lookupQuestion qkey (stateQuiz st)
  case phaseOf qkey st of
    Live -> Right ()
    _ -> Left "that question is not open"
  checked <- checkAnswer (questionBody question) answer
  let rid = ResponseId (worldNextResponse w)
      response =
        Response
          { responseId = rid
          , responseQuestion = qkey
          , responseAnswer = checked
          , responseAt = now
          , -- Anonymous free text must be approved before it can be projected.
            responseVisible = case checked of
              AnswerText{} -> False
              _ -> True
          }
  Right ([ResponseRecorded sid response], rid)

setTextVisible :: Store -> SessionId -> ResponseId -> Bool -> IO (Either Text ())
setTextVisible store sid rid visible = apply store $ \w ->
  case Map.lookup sid (worldSessions w) of
    Nothing -> Left ("no session " <> unSessionId sid)
    Just st
      | any ((== rid) . responseId) (stateResponses st) ->
          Right ([TextVisibilitySet sid rid visible], ())
      | otherwise -> Left "no such response"

-- Reading -------------------------------------------------------------------

lookupQuestion :: QuestionKey -> Quiz -> Maybe Question
lookupQuestion qkey quiz =
  case filter ((== qkey) . questionKey) (quizQuestions quiz) of
    (q : _) -> Just q
    [] -> Nothing

phaseOf :: QuestionKey -> SessionState -> Phase
phaseOf qkey = fromMaybe Pending . Map.lookup qkey . statePhases

-- | Oldest first, which is the order the presenter wants to read text in.
responsesFor :: QuestionKey -> SessionState -> [Response]
responsesFor qkey =
  reverse . filter ((== qkey) . responseQuestion) . stateResponses

data Tally
  = -- | Per-option counts (in the question's option order), and the number of
    -- responses received.
    TallyOptions [(Option, Int)] Int
  | -- | Per-point counts across the scale, and the number of responses.
    TallyScale [(Int, Int)] Int
  | -- | Each text with its visibility, and the number of responses.
    TallyTexts [(ResponseId, Text, Bool)] Int
  deriving stock (Eq, Show)

tallyFor :: Question -> [Response] -> Tally
tallyFor question responses = case questionBody question of
  BodyChoice spec -> optionTally (choiceOptions spec)
  BodyMulti spec -> optionTally (multiOptions spec)
  BodyScale spec ->
    let points = [rangeMin (scaleRange spec) .. rangeMax (scaleRange spec)]
        countAt n = length [() | AnswerScale m <- answers, m == n]
     in TallyScale [(n, countAt n) | n <- points] total
  BodyText{} ->
    TallyTexts
      [ (responseId r, t, responseVisible r)
      | r <- sortOn responseId responses
      , AnswerText t <- [responseAnswer r]
      ]
      total
  where
    answers = map responseAnswer responses
    total = length responses
    chosen = concatMap answerOptions answers
    optionTally options =
      TallyOptions
        [(o, length (filter (== optionKey o) chosen)) | o <- options]
        total

-- Random identifiers --------------------------------------------------------

-- | Read from @/dev/urandom@ rather than pulling in a random-number library:
-- the server only needs unguessable identifiers, and this has no dependencies.
randomBytes :: Int -> IO BS.ByteString
randomBytes n = withFile "/dev/urandom" ReadMode (\h -> BS.hGet h n)

randomHex :: Int -> IO Text
randomHex n = T.pack . concatMap toHex . BS.unpack <$> randomBytes n
  where
    toHex b = [hexDigit (b `div` 16), hexDigit (b `mod` 16)]
    hexDigit d = "0123456789abcdef" !! fromIntegral d

-- | Alphabet excludes characters that are ambiguous when read aloud from the
-- back of a lecture theatre: no O/0, no I/1/l.
randomCode :: Int -> IO Text
randomCode n = T.pack . map pick . BS.unpack <$> randomBytes n
  where
    alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    pick b = alphabet !! (fromIntegral b `mod` length alphabet)

-- JSON ----------------------------------------------------------------------

instance ToJSON Phase where
  toJSON = \case
    Pending -> "pending"
    Live -> "live"
    Closed -> "closed"
    Revealed -> "revealed"

instance FromJSON Phase where
  parseJSON = withText "phase" $ \case
    "pending" -> pure Pending
    "live" -> pure Live
    "closed" -> pure Closed
    "revealed" -> pure Revealed
    other -> fail ("unknown phase " <> show other)

instance ToJSON Session where
  toJSON s =
    object
      [ "id" .= unSessionId (sessionId s)
      , "code" .= unJoinCode (sessionCode s)
      , "secret" .= unSecret (sessionSecret s)
      , "quiz" .= unQuizSlug (sessionQuizSlug s)
      , "label" .= sessionLabel s
      , "created_at" .= sessionCreatedAt s
      ]

instance FromJSON Session where
  parseJSON = withObject "session" $ \o ->
    Session
      <$> (SessionId <$> o .: "id")
      <*> (JoinCode <$> o .: "code")
      <*> (Secret <$> o .: "secret")
      <*> (QuizSlug <$> o .: "quiz")
      <*> o .: "label"
      <*> o .: "created_at"

instance ToJSON Response where
  toJSON r =
    object
      [ "id" .= unResponseId (responseId r)
      , "question" .= unQuestionKey (responseQuestion r)
      , "answer" .= responseAnswer r
      , "at" .= responseAt r
      , "visible" .= responseVisible r
      ]

instance FromJSON Response where
  parseJSON = withObject "response" $ \o ->
    Response
      <$> (ResponseId <$> o .: "id")
      <*> (QuestionKey <$> o .: "question")
      <*> o .: "answer"
      <*> o .: "at"
      <*> o .: "visible"

instance ToJSON Event where
  toJSON = \case
    QuizPushed at quiz ->
      object ["event" .= t "quiz_pushed", "at" .= at, "quiz" .= quiz]
    SessionCreated s ->
      object ["event" .= t "session_created", "session" .= s]
    SessionActivated sid ->
      object ["event" .= t "session_activated", "session_id" .= unSessionId sid]
    PhaseSet sid qkey phase ->
      object
        [ "event" .= t "phase_set"
        , "session_id" .= unSessionId sid
        , "question" .= unQuestionKey qkey
        , "phase" .= phase
        ]
    ResponseRecorded sid r ->
      object
        ["event" .= t "response", "session_id" .= unSessionId sid, "response" .= r]
    TextVisibilitySet sid rid visible ->
      object
        [ "event" .= t "text_visibility"
        , "session_id" .= unSessionId sid
        , "response_id" .= unResponseId rid
        , "visible" .= visible
        ]
    where
      t = id @Text

instance FromJSON Event where
  parseJSON = withObject "event" $ \o -> do
    ty <- o .: "event" :: Parser Text
    case ty of
      "quiz_pushed" -> QuizPushed <$> o .: "at" <*> o .: "quiz"
      "session_created" -> SessionCreated <$> o .: "session"
      "session_activated" -> SessionActivated . SessionId <$> o .: "session_id"
      "phase_set" ->
        PhaseSet
          <$> (SessionId <$> o .: "session_id")
          <*> (QuestionKey <$> o .: "question")
          <*> o .: "phase"
      "response" ->
        ResponseRecorded <$> (SessionId <$> o .: "session_id") <*> o .: "response"
      "text_visibility" ->
        TextVisibilitySet
          <$> (SessionId <$> o .: "session_id")
          <*> (ResponseId <$> o .: "response_id")
          <*> o .: "visible"
      _ -> fail ("unknown event type " <> show ty)
