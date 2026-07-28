-- | Typed client for the admin API — the payoff for writing the API as a
-- servant type: these functions are derived from the same 'AdminAPI' the
-- server serves, so the CLI cannot drift out of step with it.
module Quiz.Client
  ( Admin (..)
  , admin
  ) where

import Data.Aeson (Value)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Servant.API
import Servant.Client

import Quiz.Server.Api (AdminAPI, NewSession, PhaseChange)
import Quiz.Types (Quiz)

-- | The admin calls, with the bearer token already applied.
data Admin = Admin
  { callPush :: Quiz -> ClientM Value
  , callNewSession :: NewSession -> ClientM Value
  , callPhase :: PhaseChange -> ClientM Value
  , callState :: ClientM Value
  , callLog :: ClientM Text
  }

admin :: Text -> Admin
admin token =
  Admin
    { callPush = push bearer
    , callNewSession = newSession bearer
    , callPhase = phase bearer
    , callState = state bearer
    , callLog = logC bearer
    }
  where
    bearer = Just ("Bearer " <> token)
    push :<|> newSession :<|> phase :<|> state :<|> logC =
      client (Proxy @("api" :> AdminAPI))
