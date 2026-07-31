-- | Every page the server serves.
--
-- Two audiences with opposite needs: phones held at arm's length in a dark
-- lecture theatre, and a projector seen from thirty metres. Hence two
-- stylesheets and no shared layout beyond the document shell.
--
-- No JavaScript is required for anything. The student flow is plain form POSTs;
-- liveness is @<meta http-equiv="refresh">@. The one script present records
-- which questions this browser has answered in @localStorage@ — browser-local
-- only, never sent to the server, so it is not a pseudonym.
module Quiz.Server.Html
  ( studentIndex
  , questionForm
  , donePage
  , studentNoSession
  , embedJoin
  , embedResults
  , embedNotLive
  , embedFragment
  , fragmentNotLive
  , joinFragment
  , presenterPage
  ) where

import Control.Monad (unless, when)
import Quiz.Answer (Answer (..))

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Lucid
import Text.Printf (printf)

import Quiz.Qr (qrMatrix, qrSvg)
import Quiz.Store
import Quiz.Token (FormToken (..))
import Quiz.Types

-- Student -------------------------------------------------------------------

-- | Refreshes so that a question opening appears without the student doing
-- anything. Deliberately a list of links rather than an inlined form: a
-- refreshing page must never clobber half-typed input.
studentIndex :: JoinCode -> Quiz -> [(Question, Phase)] -> Html ()
studentIndex code quiz questions =
  shell (quizTitle quiz) studentCss (Just 3) $ do
    header_ $ do
      h1_ (toHtml (quizTitle quiz))
      p_ [class_ "muted"] ("Room code " <> strong_ (toHtml (unJoinCode code)))
    case filter ((== Live) . snd) questions of
      [] -> do
        p_ [class_ "wait"] "Nothing to answer just yet."
        p_ [class_ "muted"] "This page updates by itself — leave it open."
      live -> ul_ [class_ "qlist"] (mapM_ item live)
    script_ markAnswered
  where
    item :: (Question, Phase) -> Html ()
    item (question, _) =
      li_ [data_ "qkey" (unQuestionKey (questionKey question))] $
        a_
          [href_ (studentPath code (questionKey question))]
          (toHtml (questionPrompt question))

questionForm :: JoinCode -> Question -> FormToken -> Maybe Text -> Html ()
questionForm code question token mErr =
  shell (questionPrompt question) studentCss Nothing $ do
    form_ [method_ "post", action_ (studentPath code (questionKey question))] $ do
      h1_ (toHtml (questionPrompt question))
      case mErr of
        Nothing -> pure ()
        Just err -> p_ [class_ "error"] (toHtml err)
      input_ [type_ "hidden", name_ "token", value_ (unFormToken token)]
      bodyFields (questionBody question)
      button_ [type_ "submit"] "Submit"
    p_ [class_ "muted"] $
      a_ [href_ ("/s/" <> unJoinCode code)] "Back to all questions"

bodyFields :: QuestionBody -> Html ()
bodyFields = \case
  BodyChoice spec ->
    fieldset_ (mapM_ (choiceRow "radio" "option") (choiceOptions spec))
  BodyMulti spec -> do
    fieldset_ (mapM_ (choiceRow "checkbox" "options") (multiOptions spec))
    case multiSelect spec of
      Nothing -> pure ()
      Just (Range lo hi) ->
        p_ [class_ "muted"] $
          toHtml ("Choose between " <> tshow lo <> " and " <> tshow hi <> ".")
  BodyText spec -> do
    textarea_
      [ name_ "text"
      , rows_ "5"
      , maxlength_ (tshow (textMaxLength spec))
      , required_ "required"
      , placeholder_ "Your answer"
      ]
      ""
    p_ [class_ "muted"] $
      toHtml ("Up to " <> tshow (textMaxLength spec) <> " characters.")
  BodyScale spec -> do
    fieldset_ [class_ "scale"] $
      mapM_
        (scaleRow (scaleLabels spec))
        [rangeMin (scaleRange spec) .. rangeMax (scaleRange spec)]
  BodyGrid spec -> do
    -- The scale is stated once rather than beside every proposition; the stops
    -- themselves carry only the number.
    p_ [class_ "muted"] (toHtml (gridLegend (gridRange spec) (gridLabels spec)))
    mapM_ (gridItem (gridRange spec)) (gridItems spec)
  where
    -- Signatures are required, not stylistic: lucid's Term class leaves these
    -- ambiguous without them.
    choiceRow :: Text -> Text -> Option -> Html ()
    choiceRow kind field option =
      label_ [class_ "opt"] $ do
        input_
          [ type_ kind
          , name_ field
          , value_ (unOptionKey (optionKey option))
          ]
        span_ (toHtml (optionText option))
    gridLegend :: Range -> Map.Map Int Text -> Text
    gridLegend (Range lo hi) labels =
      let end n = tshow n <> maybe "" (" " <>) (Map.lookup n labels)
       in end lo <> "  \8230  " <> end hi

    gridItem :: Range -> Option -> Html ()
    gridItem (Range lo hi) item =
      fieldset_ [class_ "grid-item"] $ do
        legend_ [class_ "grid-legend"] (toHtml (optionText item))
        div_ [class_ "grid-scale"] (mapM_ (gridStop item) [lo .. hi])

    -- Radios rather than <input type=range>: a range input always submits a
    -- value, so a proposition a student never touched is indistinguishable
    -- from one they deliberately put in the middle — which would drag every
    -- mean on the slide toward the centre with nothing to show it had
    -- happened. Radios have a genuine unset state, so `required` can insist.
    gridStop :: Option -> Int -> Html ()
    gridStop item n =
      label_ [class_ "grid-stop"] $ do
        input_
          [ type_ "radio"
          , name_ ("grid-" <> unOptionKey (optionKey item))
          , value_ (tshow n)
          , required_ "required"
          ]
        span_ [class_ "grid-dot"] mempty
        span_ [class_ "grid-num"] (toHtml (tshow n))

    scaleRow :: Map.Map Int Text -> Int -> Html ()
    scaleRow labels n =
      label_ [class_ "opt"] $ do
        input_ [type_ "radio", name_ "scale", value_ (tshow n), required_ "required"]
        span_ $ do
          strong_ (toHtml (tshow n))
          case Map.lookup n labels of
            Nothing -> pure ()
            Just l -> toHtml (" " <> l)

donePage :: JoinCode -> Question -> Maybe Bool -> Html ()
donePage code question mCorrect =
  shell "Answer recorded" studentCss Nothing $ do
    h1_ "Answer recorded"
    p_ [class_ "muted"] (toHtml (questionPrompt question))
    case mCorrect of
      Nothing -> pure ()
      Just True -> p_ [class_ "verdict good"] "That was right."
      Just False -> p_ [class_ "verdict bad"] "That wasn't right."
    p_ $ a_ [href_ ("/s/" <> unJoinCode code)] "Back to all questions"
    script_ (recordAnswered (unQuestionKey (questionKey question)))

studentNoSession :: Html ()
studentNoSession =
  shell "Nothing running" studentCss (Just 5) $ do
    h1_ "Nothing running"
    p_ [class_ "muted"] $
      "No quiz is live at the moment. If your lecturer has just started one, "
        <> "check the room code and try again."

-- Embed (projector) ---------------------------------------------------------

-- | Shown when the slide's quiz is not the active session — never a blank
-- space, and never the active session's numbers under the wrong slide. If the
-- wrong deck is up, the room should see this and say so.
--
-- Since slide embeds are deliberately unstyled, that warning is currently
-- carried by the words alone rather than by anything visually alarming.
embedNotLive :: Text -> Html ()
embedNotLive slug =
  shell "Not live" embedCss (Just 2) $
    div_ [class_ "notlive"] $ do
      p_ [class_ "big"] "Not live"
      p_ [class_ "small"] (toHtml slug)

-- | The slide students actually type from, so it shows one complete URL with
-- the join code already in it — no second step of entering a code, and no bare
-- @/s@, which is not a route at all.
--
-- @base@ is the public origin (@QUIZ_BASE_URL@); when it is unset this falls
-- back to a bare path, which is wrong on a projector but at least not a lie.
embedJoin :: Text -> Maybe (Quiz, JoinCode) -> Html ()
embedJoin _ Nothing = embedNotLive "no session"
embedJoin base (Just (quiz, code)) =
  shell (quizTitle quiz) embedCss (Just 5) $
    div_ [class_ "join"] $ do
      joinQr base code
      p_ [class_ "url"] (toHtml (joinUrl base code))

-- | Rendered for reading aloud and typing on a phone, so the scheme is
-- dropped: nobody types @https://@.
joinUrl :: Text -> JoinCode -> Text
joinUrl base code = host <> "/s/" <> unJoinCode code
  where
    host =
      T.dropWhileEnd (== '/')
        . T.replace "https://" ""
        . T.replace "http://" ""
        $ base

-- | The full URL, scheme included, for a QR reader rather than a human.
-- 'joinUrl' drops the scheme because it is meant to be read aloud; a QR code
-- needs an actual URI so a phone offers to open a link rather than run the
-- text through a search.
joinFullUrl :: Text -> JoinCode -> Text
joinFullUrl base code = T.dropWhileEnd (== '/') base <> "/s/" <> unJoinCode code

-- | The join QR, shared by the whole-document and injected-fragment forms.
-- Silently omitted if it could not be encoded — unreachable in practice, see
-- 'qrMatrix' — rather than breaking the rest of the page over it.
joinQr :: Text -> JoinCode -> Html ()
joinQr base code = case qrMatrix (joinFullUrl base code) of
  Nothing -> pure ()
  Just modules -> div_ [class_ "quiz-qr"] (toHtmlRaw (qrSvg modules))

embedResults :: Question -> Phase -> Tally -> Html ()
embedResults question phase tally =
  shell (questionPrompt question) embedCss (Just 2) $ do
    p_ [class_ "prompt"] (toHtml (questionPrompt question))
    case tally of
      TallyOptions rows total ->
        div_ [class_ "bars"] (mapM_ (optionBar phase question total) rows)
      TallyScale rows total ->
        div_
          [class_ "bars"]
          (mapM_ (\(p, n) -> scaleBar total (scalePointLabel question p, n)) rows)
      TallyTexts rows _ -> do
        let shown = [t | (_, t, True) <- rows]
        if null shown
          then p_ [class_ "small"] "No answers shown yet."
          else ul_ [class_ "texts"] (mapM_ (li_ . toHtml) shown)
      TallyGrid rows range _ ->
        div_ [class_ "bars"] (mapM_ (gridBar range) rows)

optionBar :: Phase -> Question -> Int -> (Option, Int) -> Html ()
optionBar phase question total (option, n) =
  div_ [class_ (if highlight then "bar right" else "bar")] $ do
    div_ [class_ "fill", style_ ("width:" <> tshow (percent n total) <> "%")] mempty
    span_ [class_ "label"] (toHtml (optionText option))
    span_ [class_ "n"] (toHtml (tshow n))
  where
    highlight = phase == Revealed && optionKey option `elem` correctKeys question

-- | A scale point as it should read on screen: the number, plus the author's
-- label for that point where there is one. Without them a projected scale is a
-- bare 1–5 with nothing to say which end is which — the student answering it
-- sees the labels on their own form, so the room was the only party missing
-- them.
scalePointLabel :: Question -> Int -> Text
scalePointLabel question point = case questionBody question of
  BodyScale spec
    | Just l <- Map.lookup point (scaleLabels spec) -> tshow point <> " " <> l
  _ -> tshow point

scaleBar :: Int -> (Text, Int) -> Html ()
scaleBar total (label, n) =
  div_ [class_ "bar"] $ do
    div_ [class_ "fill", style_ ("width:" <> tshow (percent n total) <> "%")] mempty
    span_ [class_ "label"] (toHtml label)
    span_ [class_ "n"] (toHtml (tshow n))

gridBar :: Range -> (Option, Maybe Double) -> Html ()
gridBar range (item, mMean) =
  div_ [class_ "bar"] $ do
    div_
      [class_ "fill", style_ ("width:" <> tshow (meanPercent range mMean) <> "%")]
      mempty
    span_ [class_ "label"] (toHtml (optionText item))
    span_ [class_ "n"] (toHtml (maybe "\8212" oneDecimal mMean))

-- | Where a mean sits along its own scale, as a percentage. A mean is a
-- position between the scale's endpoints, not a share of a total, so it is
-- mapped from the range rather than from a response count — a 1..5 question
-- whose mean is 3 is half way along, not 60% of anything.
meanPercent :: Range -> Maybe Double -> Int
meanPercent (Range lo hi) = \case
  Nothing -> 0
  Just m
    | hi > lo ->
        max 0 (min 100 (round ((m - fromIntegral lo) / fromIntegral (hi - lo) * 100)))
    | otherwise -> 0

oneDecimal :: Double -> Text
oneDecimal m = T.pack (printf "%.1f" m)

correctKeys :: Question -> [OptionKey]
correctKeys question = case questionBody question of
  BodyChoice spec -> maybe [] pure (choiceCorrect spec)
  BodyMulti spec -> multiCorrect spec
  _ -> []

percent :: Int -> Int -> Int
percent _ 0 = 0
percent n total = (n * 100) `div` total

-- Fragment (injected into a deck) -------------------------------------------

-- | Table rows, and nothing else — no document, no styles, no wrapper.
--
-- The deck owns the surrounding @<table data-quiz="…">@ and all of the
-- presentation. We emit structure and numbers: the option text, the count, and
-- the share as a @--pct@ custom property, leaving the deck to decide whether
-- that is a bar, a column, or nothing at all.
--
-- Rows rather than a @<div>@ because of how minpressive reveals content: it
-- hides un-revealed blocks with @color: rgba(0,0,0,0)@, and @<table>@ is both
-- in that selector and in its list of step elements, so a table participates in
-- the reveal automatically while a @<div>@ would sit there visible.
--
-- No response count and no phase: that is the presenter's information, and the
-- presenter page already carries it. A room reads the shape of the
-- distribution, not the denominator — and the count was the one thing on the
-- panel that changed under its own steam while nobody was looking at it.
embedFragment :: Question -> Phase -> Tally -> Html ()
embedFragment question phase tally = case tally of
  TallyOptions rows _ -> mapM_ optionRow rows
  TallyScale rows _ -> mapM_ scaleRow rows
  TallyTexts rows _ ->
    case [t | (_, t, True) <- rows] of
      [] -> pure ()
      shown -> mapM_ textRow shown
  TallyGrid rows range _ -> mapM_ (gridRow range) rows
  where
    total = case tally of
      TallyOptions _ n -> n
      TallyScale _ n -> n
      TallyTexts _ n -> n

    optionRow :: (Option, Int) -> Html ()
    optionRow (option, n) =
      row
        (phase == Revealed && optionKey option `elem` correctKeys question)
        (optionText option)
        n

    scaleRow :: (Int, Int) -> Html ()
    scaleRow (point, n) = row False (scalePointLabel question point) n

    row :: Bool -> Text -> Int -> Html ()
    row correct label n =
      tr_
        [ class_ (if correct then "quiz-row is-correct" else "quiz-row")
        , style_ ("--pct:" <> tshow (percent n total))
        ]
        $ do
          td_ [class_ "quiz-option"] (toHtml label)
          td_ [class_ "quiz-count"] (toHtml (tshow n))

    textRow :: Text -> Html ()
    textRow t = tr_ [class_ "quiz-text"] (td_ [colspan_ "2"] (toHtml t))

    -- The bar is the mean's position on the scale and the figure is the mean
    -- itself, so the column that counts elsewhere reads as an average here.
    gridRow :: Range -> (Option, Maybe Double) -> Html ()
    gridRow range (item, mMean) =
      tr_
        [class_ "quiz-row", style_ ("--pct:" <> tshow (meanPercent range mMean))]
        $ do
          td_ [class_ "quiz-option"] (toHtml (optionText item))
          td_ [class_ "quiz-count"] (toHtml (maybe "\8212" oneDecimal mMean))

-- | Shown when the slide's quiz is not the one that is live. Same reasoning as
-- 'embedNotLive', in row form.
fragmentNotLive :: Html ()
fragmentNotLive =
  tr_ [class_ "quiz-notlive"] (td_ [colspan_ "2"] "Not live")

-- | The join address, in row form, for a deck that wants it inline rather than
-- framed.
-- | The code leads and the URL sits under it as the caption: in a room, most
-- students scan and never read the address at all, so it is the fallback
-- rather than the instruction. No \"Join at\" label — a QR above a URL does
-- not need saying.
joinFragment :: Text -> JoinCode -> Html ()
joinFragment base code = do
  tr_ [class_ "quiz-qr-row"] (td_ [colspan_ "2"] (joinQr base code))
  tr_ [class_ "quiz-join"] (td_ [colspan_ "2"] (toHtml (joinUrl base code)))


-- Presenter -----------------------------------------------------------------

-- | The lectern controls. Auto-refreshes so response counts and incoming text
-- answers appear on their own; every control is a plain form POST answered
-- with a redirect, so the refresh can never re-fire one.
presenterPage :: Secret -> Bool -> SessionState -> Html ()
presenterPage secret isActive st =
  shell ("Presenter — " <> quizTitle quiz) presenterCss (Just 5) $ do
    div_ [class_ "warnbar"] "Presenter controls — never show this page on the projector."
    header_ $ do
      h1_ (toHtml (quizTitle quiz))
      p_ [class_ "muted"] $ do
        unless (T.null (sessionLabel session)) $ do
          toHtml (sessionLabel session)
          " · "
        "code "
        strong_ (toHtml (unJoinCode (sessionCode session)))
        " · "
        if isActive
          then span_ [class_ "onair"] "live now"
          else span_ [class_ "offair"] "not the live session"
      unless isActive $
        postButton ["activate"] "go" "Make this session live"
    mapM_ questionCard (quizQuestions quiz)
  where
    quiz = stateQuiz st
    session = stateSession st

    postButton :: [Text] -> Text -> Html () -> Html ()
    postButton path cls label =
      form_
        [ method_ "post"
        , action_ (T.intercalate "/" (("/p/" <> unSecret secret) : path))
        , class_ "inline"
        ]
        (button_ [class_ cls] label)

    questionCard :: Question -> Html ()
    questionCard q = section_ [class_ "card"] $ do
      let qk = questionKey q
          phase = phaseOf qk st
          responses = responsesFor qk st
      p_ [class_ "meta"] $ do
        code_ (toHtml (unQuestionKey qk))
        " · "
        toHtml (questionTypeName (questionBody q))
        " · "
        phaseBadge phase
        " · "
        toHtml (tshow (length responses))
        " answered"
      h2_ (toHtml (questionPrompt q))
      div_ [class_ "controls"] (phaseButtons qk phase (not (null (correctKeys q))))
      case questionBody q of
        BodyText{} -> textAnswers responses
        _ -> mempty

    phaseButtons :: QuestionKey -> Phase -> Bool -> Html ()
    phaseButtons qk phase revealable = case phase of
      Pending -> postButton ["open", k] "go" "Open"
      Live -> postButton ["close", k] "stop" "Close"
      Closed -> do
        when revealable $ postButton ["reveal", k] "go" "Reveal answer"
        postButton ["open", k] "quiet" "Reopen"
      Revealed -> postButton ["open", k] "quiet" "Reopen"
      where
        k = unQuestionKey qk

    phaseBadge :: Phase -> Html ()
    phaseBadge = \case
      Pending -> span_ [class_ "badge"] "not opened"
      Live -> span_ [class_ "badge onair"] "open"
      Closed -> span_ [class_ "badge"] "closed"
      Revealed -> span_ [class_ "badge"] "revealed"

    -- Oldest first, mirroring 'responsesFor'. Hidden answers carry the Show
    -- button; that promotion is the moderation step — nothing reaches the
    -- projector without a tap here.
    textAnswers :: [Response] -> Html ()
    textAnswers responses =
      ul_ [class_ "answers"] $
        mapM_ row [(r, t) | r <- responses, AnswerText t <- [responseAnswer r]]
      where
        row (r, t) =
          li_ [class_ (if responseVisible r then "shown" else "held")] $ do
            span_ [class_ "txt"] (toHtml t)
            let rid = tshow (unResponseId (responseId r))
            if responseVisible r
              then postButton ["text", rid, "hide"] "quiet" "Hide"
              else postButton ["text", rid, "show"] "go" "Show"

-- Shell ---------------------------------------------------------------------

shell :: Text -> Text -> Maybe Int -> Html () -> Html ()
shell titleText css refresh body = doctypehtml_ $ do
  head_ $ do
    meta_ [charset_ "utf-8"]
    meta_ [name_ "viewport", content_ "width=device-width, initial-scale=1"]
    case refresh of
      Nothing -> pure ()
      Just seconds -> meta_ [httpEquiv_ "refresh", content_ (tshow seconds)]
    title_ (toHtml titleText)
    style_ css
  body_ body

studentPath :: JoinCode -> QuestionKey -> Text
studentPath code qkey = "/s/" <> unJoinCode code <> "/" <> unQuestionKey qkey

tshow :: (Show a) => a -> Text
tshow = T.pack . show

-- | Browser-local only. Never sent to the server, so it cannot become an
-- identifier.
recordAnswered :: Text -> Text
recordAnswered qkey =
  T.unlines
    [ "try {"
    , "  var done = JSON.parse(localStorage.getItem('answered') || '[]');"
    , "  if (done.indexOf('" <> qkey <> "') < 0) { done.push('" <> qkey <> "'); }"
    , "  localStorage.setItem('answered', JSON.stringify(done));"
    , "} catch (e) {}"
    ]

markAnswered :: Text
markAnswered =
  T.unlines
    [ "try {"
    , "  var done = JSON.parse(localStorage.getItem('answered') || '[]');"
    , "  document.querySelectorAll('[data-qkey]').forEach(function (li) {"
    , "    if (done.indexOf(li.dataset.qkey) >= 0) { li.classList.add('answered'); }"
    , "  });"
    , "} catch (e) {}"
    ]

studentCss :: Text
studentCss =
  T.unlines
    -- Students meet this on their own phone or laptop, often in a dark room and
    -- usually in a hurry, so it is worth styling properly. The slide embeds are
    -- the opposite — see 'embedCss'.
    [ ":root { color-scheme: light dark; }"
    , "* { box-sizing: border-box; }"
    , "body { font: 17px/1.5 system-ui, sans-serif; margin: 0 auto; padding: 1.25rem; max-width: 32rem; }"
    , "h1 { font-size: 1.3rem; margin: 0 0 1rem; }"
    , ".muted { opacity: .7; font-size: .9rem; }"
    , ".wait { font-size: 1.1rem; margin: 2rem 0 .5rem; }"
    , ".error { border: 2px solid #dc2626; color: #dc2626; font-weight: 600; padding: .6rem .75rem; border-radius: .375rem; }"
    , "fieldset { border: 0; padding: 0; margin: 0 0 1rem; }"
    , -- Tap targets sized for a phone held in one hand in a dark room. The
      -- whole row is the label, so there is no need to hit the radio itself.
      ".opt { display: flex; align-items: center; gap: .75rem; border: 1px solid #9ca3af; border-radius: .5rem; padding: .9rem .85rem; margin: .5rem 0; cursor: pointer; }"
    , ".opt input { width: 1.25rem; height: 1.25rem; flex: none; }"
    , -- Selection has to be obvious at a glance: the radio alone is too small
      -- to read on a phone at arm's length.
      ".opt:has(input:checked) { border-color: #1d4ed8; border-width: 2px; padding: calc(.9rem - 1px) calc(.85rem - 1px); }"
    , "@media (hover: hover) { .opt:hover, .qlist a:hover { border-color: #1d4ed8; } }"
    , -- Laptops mean keyboard users; never remove the focus ring without
      -- replacing it.
      ":focus-visible { outline: 3px solid #1d4ed8; outline-offset: 2px; }"
    , "textarea { width: 100%; font: inherit; padding: .75rem; border-radius: .5rem; border: 1px solid #9ca3af; }"
    , "button { width: 100%; font: inherit; font-weight: 600; padding: .9rem; border: 0; border-radius: .5rem; background: #1d4ed8; color: #fff; cursor: pointer; }"
    , ".qlist { list-style: none; padding: 0; margin: 0; }"
    , ".qlist li { margin: .5rem 0; }"
    , ".qlist a { display: block; border: 1px solid #9ca3af; border-radius: .5rem; padding: .9rem .85rem; text-decoration: none; color: inherit; }"
    , ".qlist li.answered a { opacity: .55; }"
    , ".qlist li.answered a::after { content: ' · answered'; opacity: .7; font-size: .85rem; }"
    , -- A rating grid: dots on a track, so it reads as a slider while staying
      -- radios underneath (see gridStop for why that distinction matters).
      ".grid-item { margin: 0 0 1.25rem; }"
    , ".grid-legend { padding: 0; margin: 0 0 .4rem; font-weight: 600; }"
    , ".grid-scale { display: flex; align-items: flex-start; position: relative; }"
    , -- The track the stops sit on. Inset so it runs between the outer dots
      -- rather than past them.
      ".grid-scale::before { content: \"\"; position: absolute; left: 10%; right: 10%; top: 1.15rem; height: 2px; background: #9ca3af; }"
    , ".grid-stop { flex: 1; display: flex; flex-direction: column; align-items: center; gap: .3rem; padding: .5rem 0; cursor: pointer; position: relative; }"
    , ".grid-stop input { position: absolute; opacity: 0; width: 0; height: 0; }"
    , -- Canvas is the system background colour, so the dot punches through the
      -- track in light and dark alike without naming either.
      ".grid-dot { width: 1.3rem; height: 1.3rem; border-radius: 50%; border: 2px solid #9ca3af; background: Canvas; }"
    , ".grid-stop:has(input:checked) .grid-dot { background: #1d4ed8; border-color: #1d4ed8; }"
    , ".grid-num { font-size: .85rem; opacity: .7; }"
    , ".grid-stop:has(input:checked) .grid-num { opacity: 1; font-weight: 700; }"
    , ".verdict { font-weight: 600; }"
    , ".verdict.good { color: #059669; }"
    , ".verdict.bad { color: #dc2626; }"
    ]

-- | Compact and information-dense: this page is glanced at on a lectern
-- laptop or a phone beside the notes, not projected.
presenterCss :: Text
presenterCss =
  T.unlines
    [ ":root { color-scheme: light dark; }"
    , "* { box-sizing: border-box; }"
    , "body { font: 15px/1.45 system-ui, sans-serif; margin: 0 auto; padding: 0 1rem 2rem; max-width: 44rem; }"
    , ".warnbar { position: sticky; top: 0; background: #dc2626; color: #fff; font-weight: 600; text-align: center; padding: .4rem .75rem; margin: 0 -1rem .75rem; }"
    , "h1 { font-size: 1.25rem; margin: .25rem 0; }"
    , "h2 { font-size: 1rem; margin: .25rem 0 .5rem; }"
    , ".muted { opacity: .7; margin: 0 0 .5rem; }"
    , ".card { border: 1px solid #9ca3af; border-radius: .5rem; padding: .75rem .9rem; margin: .75rem 0; }"
    , ".meta { opacity: .75; font-size: .8rem; margin: 0 0 .25rem; }"
    , ".badge { border: 1px solid currentColor; border-radius: 1rem; padding: 0 .5rem; font-size: .75rem; }"
    , ".onair { color: #059669; font-weight: 700; }"
    , ".offair { color: #dc2626; font-weight: 700; }"
    , ".controls { display: flex; gap: .5rem; }"
    , "form.inline { display: inline; margin: 0; }"
    , "button { font: inherit; font-weight: 600; padding: .45rem 1rem; border: 0; border-radius: .375rem; cursor: pointer; color: #fff; }"
    , "button.go { background: #059669; }"
    , "button.stop { background: #dc2626; }"
    , "button.quiet { background: #6b7280; }"
    , ".answers { list-style: none; padding: 0; margin: .5rem 0 0; }"
    , ".answers li { display: flex; justify-content: space-between; align-items: center; gap: .75rem; border-top: 1px solid rgb(156 163 175 / .4); padding: .4rem 0; }"
    , ".answers li.held .txt { opacity: .6; font-style: italic; }"
    , ".answers .txt { overflow-wrap: anywhere; }"
    , ".answers button { padding: .25rem .7rem; font-size: .8rem; }"
    ]

-- | Slides stay plain on purpose: this sets no fonts, sizes, or colours, so an
-- embed does not argue with the deck around it.
--
-- Note that an iframe is a separate document and inherits /nothing/ from its
-- host page. Matching size and theme is therefore the deck's job — see
-- @slides/ethics-week3.md@, which scales the frame and declares the same
-- @color-scheme@ so the panels do not come out dark inside a light page.
--
-- All that remains is the geometry that turns a @div@ into a bar — without it
-- the tallies are not a chart at all — and the fill tint, which is the only
-- thing distinguishing a revealed correct answer from a wrong one.
embedCss :: Text
embedCss =
  T.unlines
    [ ":root { color-scheme: light dark; }"
    , ".bar { position: relative; overflow: hidden; border: 1px solid currentColor; padding: .2em .4em; margin: .25em 0; }"
    , -- Translucent rather than opaque so the label stays legible over it in
      -- both light and dark rendering.
      ".bar .fill { position: absolute; inset: 0 auto 0 0; background: rgb(128 128 128 / .35); }"
    , ".bar.right .fill { background: rgb(52 211 153 / .45); }"
    , -- Keeps the label and count above the fill rather than behind it.
      ".bar .label, .bar .n { position: relative; }"
    , ".bar .n { float: right; }"
    , -- Structural, not decorative: an <svg> with no width/height defaults to
      -- a 300x150 box in most browsers, which would squash the code into an
      -- unscannable rectangle. aspect-ratio is the minimum needed for it to
      -- render as a QR code at all; everything past that is left to whatever
      -- embeds this page.
      ".quiz-qr svg { display: block; width: 12rem; aspect-ratio: 1; margin: 0 auto; }"
    , ".join { text-align: center; }"
    ]
