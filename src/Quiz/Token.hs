-- | HMAC-signed form tokens.
--
-- Students are anonymous, so there is no session cookie to bind a submission
-- to. Instead the question form carries a signed token naming the session, the
-- question, and the moment it was issued. That is enough to reject a
-- submission replayed against a different question, or one posted from a tab
-- left open since last week — without the server keeping any per-student state.
--
-- It deliberately does /not/ stop a determined student submitting twice; see
-- DESIGN.md. Accidental double submission is handled by post-redirect-get.
module Quiz.Token
  ( SigningKey
  , signingKeyFromSecret
  , FormToken (..)
  , mintToken
  , TokenError (..)
  , checkToken
  , describeTokenError
  ) where

import Crypto.Hash.Algorithms (SHA256)
import Crypto.MAC.HMAC (HMAC, hmac)
import Data.ByteArray (constEq)
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (NominalDiffTime, UTCTime, diffUTCTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime, utcTimeToPOSIXSeconds)
import Text.Read (readMaybe)

newtype SigningKey = SigningKey ByteString

-- | Derived from the admin token rather than configured separately. These
-- tokens only guard against replay and staleness, so they need no stronger
-- provenance than the deployment's own secret — and deriving means one fewer
-- environment variable to set, and a key that survives a restart.
signingKeyFromSecret :: Text -> SigningKey
signingKeyFromSecret = SigningKey . TE.encodeUtf8 . ("quiz-servant/form-token/" <>)

newtype FormToken = FormToken {unFormToken :: Text}
  deriving stock (Eq, Show)

data TokenError
  = TokenMalformed
  | TokenBadSignature
  | TokenWrongQuestion
  | TokenExpired
  deriving stock (Eq, Show)

describeTokenError :: TokenError -> Text
describeTokenError = \case
  TokenMalformed -> "That form was not filled in from a question page."
  TokenBadSignature -> "That form did not come from this server."
  TokenWrongQuestion -> "That form belongs to a different question."
  TokenExpired -> "That question page is stale — reload it and try again."

-- | @signature.session.question.issuedAt@
mintToken :: SigningKey -> UTCTime -> Text -> Text -> FormToken
mintToken key now session question =
  FormToken (sign key payload <> "." <> payload)
  where
    payload = T.intercalate "." [session, question, epoch now]

checkToken
  :: SigningKey
  -> NominalDiffTime
  -- ^ Maximum age.
  -> UTCTime
  -- ^ Now.
  -> Text
  -- ^ Expected session.
  -> Text
  -- ^ Expected question.
  -> FormToken
  -> Either TokenError ()
checkToken key maxAge now session question (FormToken raw) =
  case T.splitOn "." raw of
    [given, s, q, ts] -> do
      let payload = T.intercalate "." [s, q, ts]
      -- Signature first: nothing else in the token is trustworthy until it
      -- verifies.
      if not (TE.encodeUtf8 (sign key payload) `constEq` TE.encodeUtf8 given)
        then Left TokenBadSignature
        else do
          issued <- maybe (Left TokenMalformed) Right (parseEpoch ts)
          if s /= session || q /= question
            then Left TokenWrongQuestion
            else
              if now `diffUTCTime` issued > maxAge
                then Left TokenExpired
                else Right ()
    _ -> Left TokenMalformed

sign :: SigningKey -> Text -> Text
sign (SigningKey key) payload =
  TE.decodeUtf8 (convertToBase Base16 digest)
  where
    digest :: HMAC SHA256
    digest = hmac key (TE.encodeUtf8 payload)

epoch :: UTCTime -> Text
epoch = T.pack . show @Integer . round . utcTimeToPOSIXSeconds

parseEpoch :: Text -> Maybe UTCTime
parseEpoch =
  fmap (posixSecondsToUTCTime . fromInteger) . readMaybe . T.unpack
