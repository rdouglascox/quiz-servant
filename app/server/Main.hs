module Main (main) where

import Data.Text (Text)
import Data.Text qualified as T
import Network.Wai.Handler.Warp (run)
import Network.Wai.Middleware.RequestLogger (logStdout)
import System.Environment (lookupEnv)
import System.Exit (die)
import System.IO (hPutStrLn, stderr)
import Text.Read (readMaybe)

import Quiz.Encoding (forceUtf8)
import Quiz.Server (Env (..), app)
import Quiz.Store (ReplayReport (..), openStore, storeLogPath)
import Quiz.Token (signingKeyFromSecret)

main :: IO ()
main = do
  forceUtf8

  adminToken <-
    lookupEnv "QUIZ_ADMIN_TOKEN" >>= \case
      Just t | not (null t) -> pure (T.pack t)
      _ -> die "QUIZ_ADMIN_TOKEN must be set"

  port <- envWithDefault 8080 "PORT"
  logPath <- lookupEnv "QUIZ_LOG"

  baseUrl <- maybe "" (T.strip . T.pack) <$> lookupEnv "QUIZ_BASE_URL"
  if T.null baseUrl
    then warn "no QUIZ_BASE_URL set — the join slide cannot show a URL students can type"
    else note ("base url: " <> T.unpack baseUrl)

  (store, report) <- openStore logPath

  case storeLogPath store of
    Nothing ->
      warn "no QUIZ_LOG set — running purely in memory, nothing survives a restart"
    Just path -> do
      note ("log: " <> path)
      if replayedEvents report == 0
        then note "starting from an empty log"
        else
          note $
            "replayed "
              <> show (replayedEvents report)
              <> " event(s)"
              <> if replaySkipped report > 0
                then ", skipped " <> show (replaySkipped report) <> " unreadable line(s)"
                else ""

  note ("listening on port " <> show port)
  run port . logStdout $
    app
      Env
        { envStore = store
        , envAdminToken = adminToken
        , envSigningKey = signingKeyFromSecret adminToken
        , -- Long enough to survive a student opening the page and thinking,
          -- short enough that a tab left open since last week is refused.
          envTokenMaxAge = 3 * 60 * 60
        , envBaseUrl = baseUrl
        }

envWithDefault :: Int -> String -> IO Int
envWithDefault fallback name = do
  raw <- lookupEnv name
  pure (maybe fallback id (raw >>= readMaybe))

note :: String -> IO ()
note = hPutStrLn stderr . ("quiz-servant: " <>)

warn :: Text -> IO ()
warn = note . ("warning: " <>) . T.unpack
