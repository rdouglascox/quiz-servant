-- | The API type. Split by audience, because the audiences have nothing in
-- common: students get HTML and no authentication, slides get HTML fragments,
-- and the CLI gets JSON behind a bearer token.
module Quiz.Server.Api
  ( API
  , StudentAPI
  , StudentSub
  , EmbedAPI
  , EmbedSub
  , PresenterAPI
  , PresenterSub
  , PostRedirect
  , AdminAPI
  , SubmitForm (..)
  , NewSession (..)
  , PhaseChange (..)
  , Redirect
  , answerFromForm
  ) where

import Data.Aeson
import Data.Text (Text)
import Data.Text qualified as T
import Lucid (Html)
import Servant
import Servant.HTML.Lucid (HTML)
import Web.FormUrlEncoded (FromForm (..), parseAll, parseMaybe, parseUnique)

import Quiz.Answer
import Quiz.Store (Phase)
import Quiz.Types

type API =
  StudentAPI
    :<|> EmbedAPI
    :<|> PresenterAPI
    :<|> "api" :> AdminAPI
    :<|> "healthz" :> Get '[PlainText] Text

-- | 303 rather than 302: the student's POST must not be repeatable by reload.
-- This is what makes accidental double-submission impossible without any
-- server-side per-student state.
type Redirect = Headers '[Header "Location" Text] NoContent

type StudentAPI = "s" :> Capture "code" Text :> StudentSub

-- | Everything below the join-code capture. Named so that the handler module
-- can give its router a signature without restating the shape.
type StudentSub =
  Get '[HTML] (Html ())
    -- "e" carries a rejection message, so even a failed submission comes back
    -- as a redirect and never a repeatable POST.
    :<|> Capture "question" Text :> QueryParam "e" Text :> Get '[HTML] (Html ())
    :<|> Capture "question" Text
      :> ReqBody '[FormUrlEncoded] SubmitForm
      :> Verb 'POST 303 '[HTML] Redirect
    -- "a" is the option the student chose, echoed back so immediate feedback
    -- can be shown without the server storing who answered what.
    :<|> Capture "question" Text
      :> "done"
      :> QueryParam "a" Text
      :> Get '[HTML] (Html ())

-- | Embedded in slides. URLs carry the quiz slug and question key but never a
-- session id, so a deck is authored once and runs for years.
--
-- @join@ precedes the question capture so the literal wins.
type EmbedAPI = "embed" :> Capture "slug" Text :> EmbedSub

-- | @/frag@ returns bare rows rather than a document, for a deck to fetch and
-- inject into markup it owns. That is the seamless path: injected content
-- inherits the deck's colour, scale, and theme, which nothing inside an iframe
-- ever can. The whole-document form is kept for contexts that only accept an
-- iframe embed.
-- @join@ and its fragment precede the question capture so the literals win.
-- \"join\" is therefore not usable as a question key, which "Quiz.Validate"
-- rejects rather than letting it silently shadow.
type EmbedSub =
  "join" :> Get '[HTML] (Html ())
    :<|> "join" :> "frag" :> Get '[HTML] (Html ())
    :<|> Capture "question" Text :> "frag" :> Get '[HTML] (Html ())
    :<|> Capture "question" Text :> Get '[HTML] (Html ())

-- | The lectern controls. The unguessable secret in the path is the whole of
-- the authentication: it arrives by @quizctl session@, lives in the
-- presenter's own browser, and must never appear on the projector.
--
-- Every action is a form POST answered with 303 back to the page, so the
-- page's own auto-refresh can never re-fire an action.
type PresenterAPI = "p" :> Capture "secret" Text :> PresenterSub

type PresenterSub =
  Get '[HTML] (Html ())
    :<|> "activate" :> PostRedirect
    :<|> "text"
      :> Capture "response" Int
      :> Capture "action" Text
      :> PostRedirect
    -- open | close | reveal — literal routes above win over this capture.
    :<|> Capture "action" Text :> Capture "question" Text :> PostRedirect

type PostRedirect = Verb 'POST 303 '[HTML] Redirect

type AuthHeader = Header "Authorization" Text

type AdminAPI =
  "quiz" :> AuthHeader :> ReqBody '[JSON] Quiz :> Post '[JSON] Value
    :<|> "session" :> AuthHeader :> ReqBody '[JSON] NewSession :> Post '[JSON] Value
    :<|> "phase" :> AuthHeader :> ReqBody '[JSON] PhaseChange :> Post '[JSON] Value
    :<|> "state" :> AuthHeader :> Get '[JSON] Value
    -- Every session, not just the live one: a presenter URL is unguessable by
    -- design, so without a way to list them an earlier session becomes
    -- unreachable once another supersedes it.
    :<|> "sessions" :> AuthHeader :> Get '[JSON] Value
    :<|> "log" :> AuthHeader :> Get '[PlainText] Text

data NewSession = NewSession
  { newSessionQuiz :: Text
  , newSessionLabel :: Text
  }

instance ToJSON NewSession where
  toJSON s = object ["quiz" .= newSessionQuiz s, "label" .= newSessionLabel s]

instance FromJSON NewSession where
  parseJSON = withObject "new session" $ \o ->
    NewSession <$> o .: "quiz" <*> o .:? "label" .!= ""

data PhaseChange = PhaseChange
  { phaseQuestion :: Text
  , phaseTo :: Phase
  }

instance ToJSON PhaseChange where
  toJSON c = object ["question" .= phaseQuestion c, "phase" .= phaseTo c]

instance FromJSON PhaseChange where
  parseJSON = withObject "phase change" $ \o ->
    PhaseChange <$> o .: "question" <*> o .: "phase"

-- | One form type covers every question type; which fields are populated
-- depends on what was rendered. 'answerFromForm' resolves it against the
-- question, so a mismatched submission is rejected rather than guessed at.
data SubmitForm = SubmitForm
  { submitToken :: Text
  , submitOption :: Maybe Text
  , submitOptions :: [Text]
  , submitText :: Maybe Text
  , submitScale :: Maybe Int
  }

instance FromForm SubmitForm where
  fromForm f =
    SubmitForm
      <$> parseUnique "token" f
      <*> parseMaybe "option" f
      <*> parseAll "options" f
      <*> parseMaybe "text" f
      <*> parseMaybe "scale" f

answerFromForm :: QuestionBody -> SubmitForm -> Either Text Answer
answerFromForm body form = case body of
  BodyChoice{} ->
    maybe (Left "please choose an option") (Right . AnswerChoice . OptionKey) (submitOption form)
  BodyMulti{} ->
    Right (AnswerMulti (map OptionKey (submitOptions form)))
  BodyText{} ->
    maybe (Left "please write something") (Right . AnswerText) (nonEmpty (submitText form))
  BodyScale{} ->
    maybe (Left "please pick a point on the scale") (Right . AnswerScale) (submitScale form)
  where
    nonEmpty m = do
      t <- m
      if T.null (T.strip t) then Nothing else Just t
