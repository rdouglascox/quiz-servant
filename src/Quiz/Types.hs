-- | The quiz model. YAML is the source of truth; this is what it parses into.
module Quiz.Types
  ( QuizSlug (..)
  , QuestionKey (..)
  , OptionKey (..)
  , Quiz (..)
  , FeedbackMode (..)
  , Question (..)
  , QuestionBody (..)
  , Option (..)
  , Range (..)
  , ChoiceSpec (..)
  , MultiSpec (..)
  , TextSpec (..)
  , ScaleSpec (..)
  , GridSpec (..)
  , questionTypeName
  , bodyOptions
  , feedbackName
  ) where

import Data.Map.Strict (Map)
import Data.Text (Text)

-- | Stable identifier for a quiz. Appears in slide URLs, so it must not change
-- once slides are authored against it.
newtype QuizSlug = QuizSlug {unQuizSlug :: Text}
  deriving stock (Eq, Ord, Show)

-- | Stable identifier for a question within a quiz. Also appears in slide URLs.
newtype QuestionKey = QuestionKey {unQuestionKey :: Text}
  deriving stock (Eq, Ord, Show)

-- | Stable identifier for one option. Responses record the key, never the
-- index, so options can be reordered or reworded without invalidating data.
newtype OptionKey = OptionKey {unOptionKey :: Text}
  deriving stock (Eq, Ord, Show)

data Quiz = Quiz
  { quizSlug :: QuizSlug
  , quizTitle :: Text
  , quizFeedback :: FeedbackMode
  , quizQuestions :: [Question]
  }
  deriving stock (Eq, Show)

-- | Whether, and when, students learn if they were right.
data FeedbackMode
  = FeedbackNone
  | FeedbackAfterClose
  | FeedbackImmediate
  deriving stock (Eq, Show)

data Question = Question
  { questionKey :: QuestionKey
  , questionPrompt :: Text
  , questionBody :: QuestionBody
  }
  deriving stock (Eq, Show)

data QuestionBody
  = BodyChoice ChoiceSpec
  | BodyMulti MultiSpec
  | BodyText TextSpec
  | BodyScale ScaleSpec
  | BodyGrid GridSpec
  deriving stock (Eq, Show)

data Option = Option
  { optionKey :: OptionKey
  , optionText :: Text
  }
  deriving stock (Eq, Show)

-- | An inclusive integer range, written @1..5@ in YAML.
data Range = Range
  { rangeMin :: Int
  , rangeMax :: Int
  }
  deriving stock (Eq, Show)

data ChoiceSpec = ChoiceSpec
  { choiceOptions :: [Option]
  , choiceCorrect :: Maybe OptionKey
  }
  deriving stock (Eq, Show)

data MultiSpec = MultiSpec
  { multiOptions :: [Option]
  , multiSelect :: Maybe Range
  , multiCorrect :: [OptionKey]
  }
  deriving stock (Eq, Show)

data TextSpec = TextSpec
  { textMaxLength :: Int
  }
  deriving stock (Eq, Show)

data ScaleSpec = ScaleSpec
  { scaleRange :: Range
  , scaleLabels :: Map Int Text
  }
  deriving stock (Eq, Show)

-- | One scale, applied to several propositions at once — \"how far do you
-- agree with each of these\", \"how confident are you in each\". A poll rather
-- than a quiz: there is no notion of a correct answer.
--
-- Items reuse 'Option' because they need exactly what an option needs: a
-- stable key that responses record, and display text that can be reworded
-- without invalidating last year's data.
data GridSpec = GridSpec
  { gridItems :: [Option]
  , gridRange :: Range
  , gridLabels :: Map Int Text
  }
  deriving stock (Eq, Show)

-- | The YAML @type:@ discriminator for a body, for use in error messages and
-- rendering.
questionTypeName :: QuestionBody -> Text
questionTypeName = \case
  BodyChoice{} -> "choice"
  BodyMulti{} -> "multi"
  BodyText{} -> "text"
  BodyScale{} -> "scale"
  BodyGrid{} -> "grid"

-- | The options a body offers, empty for types that have none.
bodyOptions :: QuestionBody -> [Option]
bodyOptions = \case
  BodyChoice spec -> choiceOptions spec
  BodyMulti spec -> multiOptions spec
  BodyText{} -> []
  BodyScale{} -> []
  BodyGrid spec -> gridItems spec

feedbackName :: FeedbackMode -> Text
feedbackName = \case
  FeedbackNone -> "none"
  FeedbackAfterClose -> "after_close"
  FeedbackImmediate -> "immediate"
