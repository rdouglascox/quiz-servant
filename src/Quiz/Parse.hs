-- Orphan instances are intentional: keeping decoding here rather than in
-- Quiz.Types means the model module has no aeson dependency, and these are the
-- only FromJSON instances for these types anywhere in the package, so the
-- incoherence that makes orphans dangerous cannot arise.
{-# OPTIONS_GHC -Wno-orphans #-}

-- | Hand-written YAML decoding.
--
-- The instances here are deliberately not derived: aeson's generic encoding of
-- sum types produces YAML no human wants to author, and writing them out by
-- hand is what lets the error messages name the offending question.
module Quiz.Parse
  ( loadQuizFile
  , decodeQuiz
  , decodeQuizMarkdown
  ) where

import Data.Aeson
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Pair, Parser, parseEither, prependFailure, typeMismatch)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Char (toLower)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Yaml qualified as Yaml
import System.FilePath (takeExtension)
import Text.Read (readMaybe)

import Quiz.Types

-- | Read and decode a quiz, from either a standalone YAML file or a Markdown
-- deck with the questions written into it. Syntax and schema errors come back
-- as a human-readable string, ready to print.
--
-- Dispatching on the extension rather than sniffing the contents: a @.md@ that
-- is missing its front matter should be reported as a broken deck, not
-- silently retried as YAML and reported as something stranger.
loadQuizFile :: FilePath -> IO (Either String Quiz)
loadQuizFile fp = decode <$> BS.readFile fp
  where
    decode
      | map toLower (takeExtension fp) `elem` [".md", ".markdown"] = decodeQuizMarkdown
      | otherwise = decodeQuiz

decodeQuiz :: ByteString -> Either String Quiz
decodeQuiz = first Yaml.prettyPrintParseException . Yaml.decodeEither'

-- | Read a quiz out of a Markdown deck.
--
-- The front matter supplies the header — @quiz@, @title@, @feedback@ — and
-- each fenced @quiz@ block is one question, in document order. Keeping both in
-- the deck is what stops a quiz and the slides that present it drifting apart:
-- with them in separate files you can push last year's questions under this
-- year's deck and nothing anywhere notices, because the keys still resolve.
--
-- Other front-matter keys are ignored, so a deck's @author@, @date@ and
-- @header-includes@ are none of our business.
decodeQuizMarkdown :: ByteString -> Either String Quiz
decodeQuizMarkdown raw = do
  txt <- first (const "not valid UTF-8") (TE.decodeUtf8' raw)
  let ls = T.lines txt
  header <- frontMatter ls
  questions <- traverse questionBlock (zip [1 :: Int ..] (quizFences ls))
  fields <- case header of
    Object o -> Right o
    _ -> Left "the front matter is not a mapping"
  first ("in this deck: " <>) $
    parseEither parseJSON (Object (KM.insert "questions" (toJSON questions) fields))

-- | The YAML between the opening @---@ and the next @---@ (or @...@).
frontMatter :: [Text] -> Either String Value
frontMatter ls = case ls of
  (opening : rest)
    | T.strip opening == "---" ->
        case break closes rest of
          (body, _ : _) -> first ("in the front matter:\n" <>) (decodeYamlValue (T.unlines body))
          _ -> Left "the front matter is never closed — expected a second --- line"
  _ ->
    Left
      "expected YAML front matter at the top of the file: a --- line, then quiz/title/feedback, then another ---"
  where
    closes l = T.strip l `elem` ["---", "..."]

questionBlock :: (Int, Text) -> Either String Value
questionBlock (n, body) =
  first (\e -> "in quiz block " <> show n <> ":\n" <> e) (decodeYamlValue body)

decodeYamlValue :: Text -> Either String Value
decodeYamlValue =
  first Yaml.prettyPrintParseException . Yaml.decodeEither' . TE.encodeUtf8

-- | The body of every fenced block marked as a quiz, in document order.
quizFences :: [Text] -> [Text]
quizFences = go
  where
    go [] = []
    go (l : rest) = case opensQuiz l of
      Just indent ->
        let (body, after) = break closesFence rest
         in T.unlines (map (unindent indent) body) : go (drop 1 after)
      Nothing -> go rest

-- | Does this line open a quiz fence, and at what indent? Accepts both the
-- bare @```quiz@ and pandoc's attribute form, in either class order, since
-- @```{.yaml .quiz}@ is what gets you YAML highlighting in an editor.
opensQuiz :: Text -> Maybe Int
opensQuiz line
  | T.length spaces <= 3
  , "```" `T.isPrefixOf` rest
  , isQuiz (T.dropWhile (== '`') rest) =
      Just (T.length spaces)
  | otherwise = Nothing
  where
    (spaces, rest) = T.span (== ' ') line
    isQuiz info =
      let inner = T.dropWhileEnd (== '}') (T.dropWhile (== '{') (T.strip info))
          classes = T.words (T.map (\c -> if c == ',' then ' ' else c) inner)
       in "quiz" `elem` map (T.dropWhile (== '.')) classes

closesFence :: Text -> Bool
closesFence line = T.length stripped >= 3 && T.all (== '`') stripped
  where
    stripped = T.strip line

-- | Remove the fence's own indentation from a body line, so an indented block
-- still yields YAML that starts at column zero.
unindent :: Int -> Text -> Text
unindent n line = T.replicate (max 0 (T.length spaces - n)) " " <> rest
  where
    (spaces, rest) = T.span (== ' ') line

instance FromJSON Quiz where
  parseJSON = withObject "quiz" $ \o -> do
    slug <- QuizSlug <$> o .: "quiz"
    title <- o .: "title"
    feedback <- o .:? "feedback" .!= FeedbackAfterClose
    questions <- o .: "questions"
    pure (Quiz slug title feedback questions)

instance FromJSON FeedbackMode where
  parseJSON = withText "feedback mode" $ \case
    "none" -> pure FeedbackNone
    "after_close" -> pure FeedbackAfterClose
    "immediate" -> pure FeedbackImmediate
    other ->
      fail $
        "unknown feedback mode "
          <> show other
          <> "; expected none, after_close, or immediate"

instance FromJSON Question where
  parseJSON = withObject "question" $ \o -> do
    key <- QuestionKey <$> o .: "key"
    ty <- o .: "type"
    let context = "in question '" <> T.unpack (unQuestionKey key) <> "': "
    prependFailure context $ do
      prompt <- o .: "prompt"
      body <- parseBody ty o
      pure (Question key prompt body)

instance FromJSON Option where
  parseJSON = withObject "option" $ \o ->
    Option <$> (OptionKey <$> o .: "key") <*> o .: "text"

instance FromJSON OptionKey where
  parseJSON = fmap OptionKey . parseJSON

parseBody :: Text -> Object -> Parser QuestionBody
parseBody ty o = case ty of
  "choice" ->
    fmap BodyChoice $
      ChoiceSpec
        <$> o .: "options"
        <*> o .:? "correct"
  "multi" ->
    fmap BodyMulti $
      MultiSpec
        <$> o .: "options"
        <*> (traverse parseRange =<< o .:? "select")
        <*> (o .:? "correct" .!= [])
  "text" ->
    fmap (BodyText . TextSpec) (o .:? "max_length" .!= defaultTextMaxLength)
  "scale" ->
    fmap BodyScale $
      ScaleSpec
        <$> (parseRange =<< o .: "range")
        <*> (maybe (pure Map.empty) parseLabels =<< o .:? "labels")
  "grid" ->
    fmap BodyGrid $
      GridSpec
        <$> o .: "items"
        <*> (parseRange =<< o .: "range")
        <*> (maybe (pure Map.empty) parseLabels =<< o .:? "labels")
  _ ->
    fail $
      "unknown question type "
        <> show ty
        <> "; expected choice, multi, text, scale, or grid"

defaultTextMaxLength :: Int
defaultTextMaxLength = 240

-- | Parses @1..5@, and tolerates a bare integer as a degenerate range.
parseRange :: Value -> Parser Range
parseRange v = case v of
  String s -> case T.splitOn ".." s of
    [lo, hi]
      | Just a <- readInt lo
      , Just b <- readInt hi ->
          pure (Range a b)
    _ -> fail $ "expected a range like '1..5', got " <> show s
  Number{} -> (\n -> Range n n) <$> parseJSON v
  _ -> typeMismatch "range such as 1..5" v
  where
    readInt = readMaybe . T.unpack . T.strip

-- Encoding -------------------------------------------------------------------

-- These mirror the YAML shape exactly, so the same FromJSON instances above can
-- read them back. That is what lets a pushed quiz be stored in the event log and
-- replayed on boot, and keeps the log readable.

instance ToJSON Quiz where
  toJSON q =
    object
      [ "quiz" .= unQuizSlug (quizSlug q)
      , "title" .= quizTitle q
      , "feedback" .= feedbackName (quizFeedback q)
      , "questions" .= quizQuestions q
      ]

instance ToJSON Question where
  toJSON q =
    object $
      [ "key" .= unQuestionKey (questionKey q)
      , "prompt" .= questionPrompt q
      , "type" .= questionTypeName (questionBody q)
      ]
        <> bodyFields (questionBody q)

instance ToJSON Option where
  toJSON o =
    object ["key" .= unOptionKey (optionKey o), "text" .= optionText o]

bodyFields :: QuestionBody -> [Pair]
bodyFields = \case
  BodyChoice spec ->
    ["options" .= choiceOptions spec]
      <> foldMap (\k -> ["correct" .= unOptionKey k]) (choiceCorrect spec)
  BodyMulti spec ->
    ["options" .= multiOptions spec]
      <> foldMap (\r -> ["select" .= renderRange r]) (multiSelect spec)
      <> ["correct" .= map unOptionKey (multiCorrect spec) | not (null (multiCorrect spec))]
  BodyText spec -> ["max_length" .= textMaxLength spec]
  BodyScale spec ->
    ["range" .= renderRange (scaleRange spec)]
      <> ["labels" .= labelsObject (scaleLabels spec) | not (Map.null (scaleLabels spec))]
  BodyGrid spec ->
    ["items" .= gridItems spec, "range" .= renderRange (gridRange spec)]
      <> ["labels" .= labelsObject (gridLabels spec) | not (Map.null (gridLabels spec))]

renderRange :: Range -> Text
renderRange (Range lo hi) = T.pack (show lo) <> ".." <> T.pack (show hi)

labelsObject :: Map.Map Int Text -> Value
labelsObject m = object [K.fromString (show n) .= v | (n, v) <- Map.toList m]

-- | Scale labels are a YAML mapping keyed by integers, which arrive as strings.
parseLabels :: Object -> Parser (Map.Map Int Text)
parseLabels o = Map.fromList <$> traverse step (KM.toList o)
  where
    step (k, v) = case readMaybe (K.toString k) of
      Just n -> (,) n <$> parseJSON v
      Nothing ->
        fail $
          "scale label keys must be integers, got " <> show (K.toString k)
