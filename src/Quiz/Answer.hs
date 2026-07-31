-- | What a student submits, and whether it is admissible.
--
-- Answers are checked against the question's own spec on the way in, so nothing
-- invalid ever reaches the store or the response log.
module Quiz.Answer
  ( Answer (..)
  , checkAnswer
  , answerOptions
  ) where

import Data.Aeson
import Data.Aeson.Types (Parser)
import Data.Text (Text)
import Data.Text qualified as T

import Quiz.Types

data Answer
  = AnswerChoice OptionKey
  | AnswerMulti [OptionKey]
  | AnswerText Text
  | AnswerScale Int
  | -- | One value per proposition, in the question's own item order.
    AnswerGrid [(OptionKey, Int)]
  deriving stock (Eq, Show)

instance ToJSON Answer where
  toJSON = \case
    AnswerChoice k -> object ["type" .= ("choice" :: Text), "option" .= unOptionKey k]
    AnswerMulti ks -> object ["type" .= ("multi" :: Text), "options" .= map unOptionKey ks]
    AnswerText t -> object ["type" .= ("text" :: Text), "text" .= t]
    AnswerScale n -> object ["type" .= ("scale" :: Text), "value" .= n]
    -- A list of pairs rather than an object: item order is the question's own,
    -- and a JSON object would neither promise to keep it nor read as ordered.
    AnswerGrid vs ->
      object
        [ "type" .= ("grid" :: Text)
        , "ratings" .= [object ["item" .= unOptionKey k, "value" .= v] | (k, v) <- vs]
        ]

instance FromJSON Answer where
  parseJSON = withObject "answer" $ \o -> do
    ty <- o .: "type" :: Parser Text
    case ty of
      "choice" -> AnswerChoice . OptionKey <$> o .: "option"
      "multi" -> AnswerMulti . map OptionKey <$> o .: "options"
      "text" -> AnswerText <$> o .: "text"
      "scale" -> AnswerScale <$> o .: "value"
      "grid" -> do
        rows <- o .: "ratings"
        AnswerGrid
          <$> traverse
            (withObject "rating" (\r -> (,) <$> (OptionKey <$> r .: "item") <*> r .: "value"))
            rows
      _ -> fail ("unknown answer type " <> show ty)

-- | The option keys an answer selected, for tallying.
answerOptions :: Answer -> [OptionKey]
answerOptions = \case
  AnswerChoice k -> [k]
  AnswerMulti ks -> ks
  AnswerText{} -> []
  AnswerScale{} -> []

-- | Validate an answer against the question it claims to answer, normalising
-- it on the way through (text is stripped, multi-selections deduplicated and
-- put in the question's own option order).
checkAnswer :: QuestionBody -> Answer -> Either Text Answer
checkAnswer body answer = case (body, answer) of
  (BodyChoice spec, AnswerChoice k)
    | k `elem` keysOf (choiceOptions spec) -> Right (AnswerChoice k)
    | otherwise -> Left "that is not one of the options"
  (BodyMulti spec, AnswerMulti ks)
    | not (all (`elem` keysOf (multiOptions spec)) ks) ->
        Left "that is not one of the options"
    | otherwise ->
        let chosen = filter (`elem` ks) (keysOf (multiOptions spec))
            n = length chosen
         in case multiSelect spec of
              Just (Range lo hi)
                | n < lo -> Left (needAtLeast lo)
                | n > hi -> Left (needAtMost hi)
              _
                | n == 0 -> Left "choose at least one option"
              _ -> Right (AnswerMulti chosen)
  (BodyText spec, AnswerText raw) ->
    let t = T.strip raw
     in if T.null t
          then Left "please write something"
          else
            if T.length t > textMaxLength spec
              then Left (tooLong (textMaxLength spec))
              else Right (AnswerText t)
  (BodyScale spec, AnswerScale n)
    | n >= rangeMin (scaleRange spec) && n <= rangeMax (scaleRange spec) ->
        Right (AnswerScale n)
    | otherwise -> Left "that is not on the scale"
  (BodyGrid spec, AnswerGrid given)
    -- Every proposition must be rated. A partial grid would quietly change
    -- the denominator per item, so a mean could be over a different set of
    -- students for each row without anything on the slide saying so.
    | not (null missing) -> Left "please rate every one"
    | not (all inRange (map snd given)) -> Left "that is not on the scale"
    | otherwise -> Right (AnswerGrid ordered)
    where
      items = keysOf (gridItems spec)
      missing = [k | k <- items, k `notElem` map fst given]
      Range lo hi = gridRange spec
      inRange v = v >= lo && v <= hi
      -- Normalised to the question's item order, and unknown keys dropped, so
      -- what is logged does not depend on how the browser ordered the form.
      ordered = [(k, v) | k <- items, (k', v) <- given, k == k']
  _ -> Left "that answer does not match the question"
  where
    keysOf = map optionKey
    needAtLeast lo = "choose at least " <> tshow lo <> plural lo " option"
    needAtMost hi = "choose at most " <> tshow hi <> plural hi " option"
    tooLong n = "please keep it under " <> tshow n <> " characters"
    plural n s = s <> if n == (1 :: Int) then "" else "s"
    tshow :: (Show a) => a -> Text
    tshow = T.pack . show
