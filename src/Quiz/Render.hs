-- | Static HTML preview of a quiz.
--
-- This exists so a quiz can be eyeballed without deploying anything, and it
-- doubles as the offline fallback: if the server is unreachable mid-lecture,
-- the questions can still be put on screen.
module Quiz.Render
  ( renderQuizPreview
  ) where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Lazy qualified as TL
import Lucid

import Quiz.Types

renderQuizPreview :: Quiz -> TL.Text
renderQuizPreview = renderText . quizDoc

quizDoc :: Quiz -> Html ()
quizDoc Quiz{..} = doctypehtml_ $ do
  head_ $ do
    meta_ [charset_ "utf-8"]
    meta_ [name_ "viewport", content_ "width=device-width, initial-scale=1"]
    title_ (toHtml quizTitle)
    style_ previewCss
  body_ $ do
    header_ $ do
      h1_ (toHtml quizTitle)
      p_ [class_ "meta"] $ do
        code_ (toHtml (unQuizSlug quizSlug))
        " · feedback: "
        toHtml (feedbackName quizFeedback)
        " · "
        toHtml (tshow (length quizQuestions))
        " questions"
    mapM_ questionCard (zip [1 ..] quizQuestions)

questionCard :: (Int, Question) -> Html ()
questionCard (n, Question{..}) = section_ [class_ "card"] $ do
  p_ [class_ "meta"] $ do
    toHtml ("Q" <> tshow n)
    " · "
    code_ (toHtml (unQuestionKey questionKey))
    " · "
    toHtml (questionTypeName questionBody)
  h2_ (toHtml questionPrompt)
  bodyHtml questionBody

bodyHtml :: QuestionBody -> Html ()
bodyHtml = \case
  BodyChoice ChoiceSpec{..} ->
    ul_ [class_ "options"] $
      mapM_ (optionItem (`elem` maybe [] pure choiceCorrect)) choiceOptions
  BodyMulti MultiSpec{..} -> do
    ul_ [class_ "options"] $
      mapM_ (optionItem (`elem` multiCorrect)) multiOptions
    case multiSelect of
      Nothing -> pure ()
      Just r -> p_ [class_ "meta"] (toHtml ("select " <> renderRange r))
  BodyText TextSpec{..} -> do
    p_ [class_ "free-text"] "(free text)"
    p_ [class_ "meta"] $
      toHtml ("up to " <> tshow textMaxLength <> " characters · moderated before display")
  BodyScale ScaleSpec{..} ->
    ul_ [class_ "options"] $
      mapM_ (scaleItem scaleLabels) [rangeMin scaleRange .. rangeMax scaleRange]

optionItem :: (OptionKey -> Bool) -> Option -> Html ()
optionItem isCorrect Option{..} =
  li_ [class_ (if isCorrect optionKey then "correct" else "")] $ do
    toHtml optionText
    code_ (toHtml (unOptionKey optionKey))

scaleItem :: Map.Map Int Text -> Int -> Html ()
scaleItem labels n = li_ $ do
  toHtml (tshow n)
  case Map.lookup n labels of
    Nothing -> pure ()
    Just label -> span_ [class_ "meta"] (toHtml (" " <> label))

renderRange :: Range -> Text
renderRange (Range lo hi) = tshow lo <> ".." <> tshow hi

tshow :: (Show a) => a -> Text
tshow = T.pack . show

previewCss :: Text
previewCss =
  T.unlines
    [ ":root { color-scheme: light dark; }"
    , "body { font: 16px/1.5 system-ui, sans-serif; margin: 0 auto; padding: 2rem 1rem; max-width: 42rem; }"
    , "h1 { font-size: 1.5rem; margin: 0 0 .25rem; }"
    , "h2 { font-size: 1.15rem; margin: 0 0 .75rem; }"
    , ".meta { color: #6b7280; font-size: .8rem; margin: 0 0 .5rem; }"
    , ".card { border: 1px solid #d1d5db; border-radius: .5rem; padding: 1rem; margin: 1rem 0; }"
    , ".options { list-style: none; padding: 0; margin: 0; }"
    , ".options li { border: 1px solid #d1d5db; border-radius: .375rem; padding: .6rem .75rem; margin: .35rem 0; display: flex; justify-content: space-between; gap: 1rem; }"
    , ".options li.correct { border-color: #059669; }"
    , ".options code, .meta code { color: #6b7280; font-size: .75rem; }"
    , ".free-text { border: 1px dashed #d1d5db; border-radius: .375rem; padding: 1.25rem .75rem; color: #6b7280; margin: 0 0 .5rem; }"
    ]
