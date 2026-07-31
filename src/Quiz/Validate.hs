-- | Semantic checks that parsing cannot express.
--
-- Parsing is permissive about anything that is structurally well-formed;
-- everything else is reported here, all at once, so a single @quizctl validate@
-- run tells you about every problem rather than the first one.
module Quiz.Validate
  ( Problem (..)
  , validateQuiz
  , formatProblem
  ) where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T

import Quiz.Types

data Problem = Problem
  { problemWhere :: Text
  , problemWhat :: Text
  }
  deriving stock (Eq, Show)

formatProblem :: Problem -> Text
formatProblem p = problemWhere p <> ": " <> problemWhat p

-- | All problems with a quiz. An empty list means it is fit to push.
validateQuiz :: Quiz -> [Problem]
validateQuiz Quiz{..} =
  concat
    [ [ Problem "quiz" ("slug must match [a-z0-9-]+, got " <> tshow (unQuizSlug quizSlug))
      | not (validKey (unQuizSlug quizSlug))
      ]
    , [Problem "quiz" "title must not be empty" | T.null (T.strip quizTitle)]
    , [Problem "quiz" "must have at least one question" | null quizQuestions]
    , duplicates "quiz" "duplicate question key" (map (unQuestionKey . questionKey) quizQuestions)
    , concatMap validateQuestion quizQuestions
    ]

validateQuestion :: Question -> [Problem]
validateQuestion Question{..} =
  concat
    [ [Problem context "prompt must not be empty" | T.null (T.strip questionPrompt)]
    , [ Problem context ("key must match [a-z0-9-]+, got " <> tshow (unQuestionKey questionKey))
      | not (validKey (unQuestionKey questionKey))
      ]
    , [ Problem context "'join' is reserved — the join panel uses that path"
      | unQuestionKey questionKey == "join"
      ]
    , bodyProblems
    ]
  where
    context = "question '" <> unQuestionKey questionKey <> "'"

    options = bodyOptions questionBody
    optionKeys = map (unOptionKey . optionKey) options

    bodyProblems = case questionBody of
      BodyChoice ChoiceSpec{..} ->
        optionProblems
          <> concatMap correctMustExist (maybe [] pure choiceCorrect)
      BodyMulti MultiSpec{..} ->
        optionProblems
          <> concatMap correctMustExist multiCorrect
          <> maybe [] selectProblems multiSelect
      BodyText TextSpec{..} ->
        [Problem context "max_length must be positive" | textMaxLength <= 0]
      BodyScale ScaleSpec{..} -> scaleProblems scaleRange scaleLabels
      BodyGrid GridSpec{..} ->
        -- A grid's items are checked by the same rules as options: they need
        -- at least two, with distinct keys, for exactly the same reasons.
        optionProblems <> scaleProblems gridRange gridLabels

    -- Shared by scale and grid, which differ in what is rated, not in how.
    scaleProblems theRange theLabels =
      [ Problem context ("range must be increasing, got " <> renderRange theRange)
      | rangeMin theRange >= rangeMax theRange
      ]
        <> [ Problem context ("label " <> tshow n <> " falls outside " <> renderRange theRange)
           | n <- Map.keys theLabels
           , n < rangeMin theRange || n > rangeMax theRange
           ]

    -- A grid rates propositions rather than offering choices, so the same
    -- checks should not tell its author about "options" they never wrote.
    noun = case questionBody of
      BodyGrid{} -> "item"
      _ -> "option"

    optionProblems =
      [Problem context ("must offer at least two " <> noun <> "s") | length options < 2]
        <> duplicates context ("duplicate " <> noun <> " key") optionKeys

    correctMustExist k =
      [ Problem context ("correct answer '" <> unOptionKey k <> "' is not one of the options")
      | unOptionKey k `notElem` optionKeys
      ]

    selectProblems (Range lo hi) =
      concat
        [ [Problem context "select minimum must be at least 1" | lo < 1]
        , [Problem context "select range must be increasing" | lo > hi]
        , [ Problem context ("select maximum " <> tshow hi <> " exceeds the " <> tshow (length options) <> " options")
          | hi > length options
          ]
        ]

-- | Keys appear in URLs, so keep them to an unambiguous alphabet.
validKey :: Text -> Bool
validKey t = not (T.null t) && T.all ok t
  where
    ok c = c `elem` ['a' .. 'z'] || c `elem` ['0' .. '9'] || c == '-'

duplicates :: Text -> Text -> [Text] -> [Problem]
duplicates context label = go []
  where
    go _ [] = []
    go seen (x : xs)
      | x `elem` seen = Problem context (label <> " " <> tshow x) : go seen xs
      | otherwise = go (x : seen) xs

renderRange :: Range -> Text
renderRange (Range lo hi) = tshow lo <> ".." <> tshow hi

tshow :: (Show a) => a -> Text
tshow = T.pack . show
