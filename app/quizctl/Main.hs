module Main (main) where

import Data.Aeson (Value, encode, fromJSON)
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseMaybe, withObject, (.:))
import Data.Aeson.Types qualified as AT
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Lazy.Char8 qualified as BLC
import Data.Foldable (for_)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Text.Lazy.IO qualified as TLIO
import Data.Traversable (for)
import Network.HTTP.Client.TLS (newTlsManager)
import Network.HTTP.Types.Status (statusCode)
import Options.Applicative
import Servant.Client
import System.Directory (XdgDirectory (XdgConfig), doesFileExist, getXdgDirectory)
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)

import Quiz.Client
import Quiz.Encoding (forceUtf8)
import Quiz.Parse (loadQuizFile)
import Quiz.Render (renderQuizPreview)
import Quiz.Server.Api (NewSession (..), PhaseChange (..))
import Quiz.Store
  ( JoinCode (..)
  , Phase (..)
  , Secret (..)
  , Session (..)
  )
import Quiz.Types
import Quiz.Validate (formatProblem, validateQuiz)

data Command
  = Validate ValidateOpts
  | Push FilePath
  | SessionNew Text Text
  | SetPhase Phase Text
  | Status
  | Sessions
  | Pull (Maybe FilePath)

data ValidateOpts = ValidateOpts
  { validatePath :: FilePath
  , validateHtmlOut :: Maybe FilePath
  , validateJsonOut :: Maybe FilePath
  }

main :: IO ()
main = do
  forceUtf8
  run =<< execParser parser
  where
    parser =
      info
        (commands <**> helper)
        ( fullDesc
            <> progDesc "Author, push, and run minimal lecture quizzes."
            <> header "quizctl"
        )

commands :: Parser Command
commands =
  hsubparser $
    command
      "validate"
      ( info
          (Validate <$> validateOpts)
          (progDesc "Check a quiz file, and optionally render a static preview")
      )
      <> command
        "push"
        ( info
            (Push <$> argument str (metavar "FILE" <> help "Quiz YAML file"))
            (progDesc "Validate a quiz file and push it to the server")
        )
      <> command
        "session"
        ( info
            ( SessionNew
                <$> argument str (metavar "SLUG" <> help "Slug of a pushed quiz")
                <*> strOption
                  ( long "label"
                      <> metavar "LABEL"
                      <> value ""
                      <> help "Cohort label, e.g. \"2026 S2 W3\""
                  )
            )
            (progDesc "Create a session for a pushed quiz and make it live")
        )
      <> command
        "open"
        (info (SetPhase Live <$> qkeyArg) (progDesc "Open a question for answers"))
      <> command
        "close"
        (info (SetPhase Closed <$> qkeyArg) (progDesc "Stop accepting answers"))
      <> command
        "reveal"
        ( info
            (SetPhase Revealed <$> qkeyArg)
            (progDesc "Close a question and highlight the correct answer")
        )
      <> command
        "status"
        (info (pure Status) (progDesc "Show the live session and its questions"))
      <> command
        "sessions"
        ( info
            (pure Sessions)
            (progDesc "List every session, with its presenter link")
        )
      <> command
        "pull"
        ( info
            ( Pull
                <$> optional
                  ( strOption
                      ( long "out"
                          <> metavar "FILE"
                          <> help "Write to FILE instead of stdout"
                      )
                  )
            )
            (progDesc "Download the response log (JSONL)")
        )
  where
    qkeyArg = argument str (metavar "QUESTION" <> help "Question key from the YAML")

validateOpts :: Parser ValidateOpts
validateOpts =
  ValidateOpts
    <$> argument str (metavar "FILE" <> help "Path to a quiz YAML file")
    <*> optional
      ( strOption
          ( long "html"
              <> metavar "OUT"
              <> help "Write a static HTML preview of the quiz to OUT"
          )
      )
    <*> optional
      ( strOption
          ( long "json"
              <> metavar "OUT"
              <> help "Write the quiz as canonical JSON — exactly what push sends"
          )
      )

run :: Command -> IO ()
run = \case
  Validate opts -> runValidate opts
  Push path -> do
    quiz <- loadValidated path
    (remote, base) <- connect
    reply <- runRemote base (callPush remote quiz)
    let n = maybe "?" show (parseMaybe questionCount reply)
    putStrLn $
      "pushed "
        <> T.unpack (unQuizSlug (quizSlug quiz))
        <> " ("
        <> n
        <> " questions) to "
        <> showBaseUrl base
  SessionNew slug label -> do
    (remote, base) <- connect
    reply <- runRemote base (callNewSession remote (NewSession slug label))
    session <- case fromJSON reply of
      Aeson.Success s -> pure (s :: Session)
      Aeson.Error e -> die' "server reply was not a session" (T.pack e)
    let url path = showBaseUrl base <> T.unpack path
    putStrLn "session created and made live"
    putStrLn ("  join code:  " <> T.unpack (unJoinCode (sessionCode session)))
    putStrLn ("  students:   " <> url ("/s/" <> unJoinCode (sessionCode session)))
    putStrLn ("  join slide: " <> url ("/embed/" <> slug <> "/join"))
    putStrLn ("  presenter:  " <> url ("/p/" <> unSecret (sessionSecret session)))
    putStrLn "the presenter link is a secret — never put it on the projector"
  SetPhase phase qkey -> do
    (remote, base) <- connect
    _ <- runRemote base (callPhase remote (PhaseChange qkey phase))
    putStrLn (T.unpack qkey <> " → " <> phaseWord phase)
  Status -> do
    (remote, base) <- connect
    reply <- runRemote base (callState remote)
    case parseMaybe stateReply reply of
      Nothing -> putStrLn "no live session"
      Just (session, rows) -> do
        putStrLn $
          "live: "
            <> T.unpack (unQuizSlug (sessionQuizSlug session))
            <> (if T.null (sessionLabel session) then "" else " — " <> T.unpack (sessionLabel session))
            <> " (code "
            <> T.unpack (unJoinCode (sessionCode session))
            <> ")"
        putStrLn ("presenter: " <> showBaseUrl base <> "/p/" <> T.unpack (unSecret (sessionSecret session)))
        for_ rows $ \(key, ty, phase, n) ->
          TIO.putStrLn $
            "  "
              <> T.justifyLeft 24 ' ' key
              <> T.justifyLeft 8 ' ' ty
              <> T.justifyLeft 10 ' ' phase
              <> T.pack (show (n :: Int))
  Sessions -> do
    (remote, base) <- connect
    reply <- runRemote base (callSessions remote)
    case parseMaybe sessionsReply reply of
      Nothing -> die' "server reply was not a session list" ""
      Just [] -> putStrLn "no sessions yet — quizctl session <slug> starts one"
      Just rows -> for_ rows $ \r -> do
        TIO.putStrLn $
          (if sessionIsActive r then "* " else "  ")
            <> T.justifyLeft 7 ' ' (sessionRowCode r)
            <> T.justifyLeft 24 ' ' (sessionRowQuiz r)
            <> T.justifyLeft 22 ' ' (sessionRowLabel r)
            <> T.pack (show (sessionRowResponses r) <> " responses")
        putStrLn $ "    " <> showBaseUrl base <> "/p/" <> T.unpack (sessionRowSecret r)
      -- The leading marker is the live session; every line's link still works,
      -- which is the point of listing them.
  Pull mOut -> do
    (remote, base) <- connect
    contents <- runRemote base (callLog remote)
    if T.null contents
      then hPutStrLn stderr "the response log is empty"
      else case mOut of
        Nothing -> TIO.putStr contents
        Just out -> do
          TIO.writeFile out contents
          hPutStrLn stderr ("wrote " <> show (length (T.lines contents)) <> " events to " <> out)

-- Wire ----------------------------------------------------------------------

-- | Server location and token: @QUIZ_URL@ / @QUIZ_TOKEN@, falling back to
-- files under @~/.config/quizctl/@.
connect :: IO (Admin, BaseUrl)
connect = do
  url <- setting "QUIZ_URL" "url"
  token <- setting "QUIZ_TOKEN" "token"
  base <- case parseBaseUrl (T.unpack url) of
    Just b -> pure b
    Nothing -> die' ("not a usable server URL: " <> T.unpack url) ""
  pure (admin token, base)

setting :: String -> FilePath -> IO Text
setting envName fileName = do
  fromEnv <- lookupEnv envName
  case T.strip . T.pack <$> fromEnv of
    Just v | not (T.null v) -> pure v
    _ -> do
      dir <- getXdgDirectory XdgConfig "quizctl"
      let path = dir </> fileName
      exists <- doesFileExist path
      if exists
        then T.strip <$> TIO.readFile path
        else
          die'
            ("no server configured: set " <> envName <> " or write " <> path)
            ""

runRemote :: BaseUrl -> ClientM a -> IO a
runRemote base act = do
  manager <- newTlsManager
  runClientM act (mkClientEnv manager base) >>= \case
    Right a -> pure a
    Left err -> die' "request failed" (describeClientError err)

describeClientError :: ClientError -> Text
describeClientError = \case
  FailureResponse _ resp ->
    "server said "
      <> T.pack (show (statusCode (responseStatusCode resp)))
      <> ":\n"
      <> T.pack (BLC.unpack (responseBody resp))
  ConnectionError e -> "could not reach the server: " <> T.pack (show e)
  other -> T.pack (show other)

-- Replies -------------------------------------------------------------------

questionCount :: Value -> AT.Parser Int
questionCount = withObject "push reply" (.: "questions")

stateReply :: Value -> AT.Parser (Session, [(Text, Text, Text, Int)])
stateReply = withObject "state" $ \o -> do
  active <- o .: "active"
  if not active
    then fail "no active session"
    else do
      session <- o .: "session"
      questions <- o .: "questions"
      rows <- for questions . withObject "question" $ \q ->
        (,,,) <$> q .: "key" <*> q .: "type" <*> q .: "phase" <*> q .: "responses"
      pure (session, rows)

data SessionRow = SessionRow
  { sessionRowCode :: Text
  , sessionRowQuiz :: Text
  , sessionRowLabel :: Text
  , sessionRowSecret :: Text
  , sessionRowResponses :: Int
  , sessionIsActive :: Bool
  }

sessionsReply :: Value -> AT.Parser [SessionRow]
sessionsReply = withObject "sessions" $ \o -> do
  rows <- o .: "sessions"
  for rows . withObject "session" $ \s ->
    SessionRow
      <$> s .: "code"
      <*> s .: "quiz"
      <*> s .: "label"
      <*> s .: "secret"
      <*> s .: "responses"
      <*> s .: "active"

phaseWord :: Phase -> String
phaseWord = \case
  Pending -> "pending"
  Live -> "open"
  Closed -> "closed"
  Revealed -> "revealed"

-- Validate ------------------------------------------------------------------

runValidate :: ValidateOpts -> IO ()
runValidate ValidateOpts{..} = do
  quiz <- loadValidated validatePath

  putStrLn $
    validatePath
      <> ": ok — "
      <> T.unpack (unQuizSlug (quizSlug quiz))
      <> ", "
      <> show (length (quizQuestions quiz))
      <> " question(s)"

  for_ validateHtmlOut $ \out -> do
    TLIO.writeFile out (renderQuizPreview quiz)
    putStrLn ("wrote preview to " <> out)

  for_ validateJsonOut $ \out -> do
    BL.writeFile out (encode quiz)
    putStrLn ("wrote json to " <> out)

-- | Parse and validate, or die with every problem listed. Shared by
-- @validate@ and @push@, so nothing invalid can be pushed.
loadValidated :: FilePath -> IO Quiz
loadValidated path = do
  parsed <- loadQuizFile path
  quiz <- case parsed of
    Left err -> die' (path <> ": could not be parsed") (T.pack err)
    Right q -> pure q
  case validateQuiz quiz of
    [] -> pure quiz
    problems -> do
      hPutStrLn stderr (path <> ": " <> show (length problems) <> " problem(s)")
      for_ problems $ \p -> TIO.hPutStrLn stderr ("  " <> formatProblem p)
      exitFailure

die' :: String -> T.Text -> IO a
die' summary detail = do
  hPutStrLn stderr summary
  if T.null detail then pure () else TIO.hPutStrLn stderr detail
  exitFailure
