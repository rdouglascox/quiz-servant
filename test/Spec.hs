module Main (main) where

import Data.ByteString (ByteString)
import Data.Char (isAsciiLower, isDigit)
import Control.Monad (void)
import Data.Either (isLeft)
import Data.Foldable (for_)
import Data.List (isInfixOf)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Quiz.Answer
import Quiz.Parse (decodeQuiz, decodeQuizMarkdown, loadQuizFile)
import Quiz.Store
import Quiz.Token
import Quiz.Types
import Quiz.Validate (formatProblem, validateQuiz)

main :: IO ()
main = hspec $ do
  describe "parsing" parsingSpec
  describe "validation" validationSpec
  describe "examples" examplesSpec
  describe "form tokens" tokenSpec
  describe "store" storeSpec

tokenSpec :: Spec
tokenSpec = do
  let key = signingKeyFromSecret "admin-secret"
      now = epoch 1000
      check = checkToken key 3600

  it "accepts a token it just minted" $
    check now "sess" "q1" (mintToken key now "sess" "q1") `shouldBe` Right ()

  it "rejects a token minted for a different question" $
    check now "sess" "q2" (mintToken key now "sess" "q1")
      `shouldBe` Left TokenWrongQuestion

  it "rejects a token minted for a different session" $
    check now "other" "q1" (mintToken key now "sess" "q1")
      `shouldBe` Left TokenWrongQuestion

  it "rejects a token older than the maximum age" $
    check (epoch 5000) "sess" "q1" (mintToken key now "sess" "q1")
      `shouldBe` Left TokenExpired

  it "rejects a token signed with a different key" $
    check now "sess" "q1" (mintToken (signingKeyFromSecret "other") now "sess" "q1")
      `shouldBe` Left TokenBadSignature

  it "rejects a token whose payload has been edited" $ do
    let FormToken raw = mintToken key now "sess" "q1"
        tampered = FormToken (T.replace ".sess." ".admin." raw)
    check now "sess" "q1" tampered `shouldSatisfy` (/= Right ())

  it "rejects a token that is not a token" $
    check now "sess" "q1" (FormToken "garbage") `shouldBe` Left TokenMalformed

storeSpec :: Spec
storeSpec = do
  it "refuses answers to a question that is not open" $ do
    (store, sid) <- seeded Nothing
    result <- recordResponse store (epoch 0) sid choiceKey (AnswerChoice (OptionKey "a"))
    result `shouldSatisfy` isLeft

  it "accepts answers once the question is open, and tallies them" $ do
    (store, sid) <- seeded Nothing
    must (setPhase store sid choiceKey Live)
    for_ ["a", "a", "b"] $ \o ->
      must (recordResponse store (epoch 0) sid choiceKey (AnswerChoice (OptionKey o)))
    st <- activeOf store
    case tallyFor (questionNamed choiceKey st) (responsesFor choiceKey st) of
      TallyOptions counts total -> do
        total `shouldBe` 3
        map snd counts `shouldBe` [2, 1]
      other -> expectationFailure ("unexpected tally: " <> show other)

  it "rejects an answer that is not one of the options" $ do
    (store, sid) <- seeded Nothing
    must (setPhase store sid choiceKey Live)
    result <- recordResponse store (epoch 0) sid choiceKey (AnswerChoice (OptionKey "nope"))
    result `shouldSatisfy` isLeft

  it "rejects a scale answer outside the range" $ do
    (store, sid) <- seeded Nothing
    must (setPhase store sid scaleKey Live)
    result <- recordResponse store (epoch 0) sid scaleKey (AnswerScale 99)
    result `shouldSatisfy` isLeft

  it "holds free text back from display until it is promoted" $ do
    (store, sid) <- seeded Nothing
    must (setPhase store sid textKey Live)
    rid <- must (recordResponse store (epoch 0) sid textKey (AnswerText "hello"))
    visibilityOf store textKey `shouldReturn` [False]
    must (setTextVisible store sid rid True)
    visibilityOf store textKey `shouldReturn` [True]

  it "finds a session by its presenter secret, active or not" $ do
    (store, sid) <- seeded Nothing
    secret <- secretOf store sid
    -- A second session displaces the first as the live one…
    second <- freshSession (epoch 1) (quizSlug storeQuiz) "second"
    must (createSession store second)
    world <- readWorld store
    -- …but the first is still reachable by its secret, and a wrong secret is not.
    (sessionId . stateSession <$> sessionBySecret secret world) `shouldBe` Just sid
    sessionBySecret (Secret "wrong") world `shouldBe` Nothing

  -- Deactivation must discard nothing: reactivating an earlier session (a
  -- make-up class) restores its tallies.
  it "keeps a superseded session's responses for reactivation" $ do
    (store, sid) <- seeded Nothing
    must (setPhase store sid choiceKey Live)
    must_ (recordResponse store (epoch 0) sid choiceKey (AnswerChoice (OptionKey "a")))
    second <- freshSession (epoch 1) (quizSlug storeQuiz) "second"
    must (createSession store second)
    must_ (activateSession store sid)
    st <- activeOf store
    sessionId (stateSession st) `shouldBe` sid
    length (responsesFor choiceKey st) `shouldBe` 1

  it "averages a grid per proposition" $ do
    (store, sid) <- seeded Nothing
    must (setPhase store sid gridKey Live)
    -- P: 1 and 4 -> 2.5.  Q: 5 and 4 -> 4.5.
    for_ [[("p", 1), ("q", 5)], [("p", 4), ("q", 4)]] $ \rating ->
      must_
        ( recordResponse store (epoch 0) sid gridKey $
            AnswerGrid [(OptionKey k, v) | (k, v) <- rating]
        )
    st <- activeOf store
    case tallyFor (questionNamed gridKey st) (responsesFor gridKey st) of
      TallyGrid rows range total -> do
        total `shouldBe` 2
        range `shouldBe` Range 1 5
        -- Exactly representable, so an equality check is honest here.
        map snd rows `shouldBe` [Just 2.5, Just 4.5]
        map (optionText . fst) rows `shouldBe` ["P", "Q"]
      other -> expectationFailure ("unexpected tally: " <> show other)

  -- A partial grid would give each proposition a different denominator, so a
  -- row of means would silently be over different sets of students.
  it "refuses a grid that leaves a proposition unrated" $ do
    (store, sid) <- seeded Nothing
    must (setPhase store sid gridKey Live)
    result <-
      recordResponse store (epoch 0) sid gridKey (AnswerGrid [(OptionKey "p", 3)])
    result `shouldSatisfy` isLeft

  it "refuses a grid rating outside the scale" $ do
    (store, sid) <- seeded Nothing
    must (setPhase store sid gridKey Live)
    result <-
      recordResponse
        store
        (epoch 0)
        sid
        gridKey
        (AnswerGrid [(OptionKey "p", 3), (OptionKey "q", 99)])
    result `shouldSatisfy` isLeft

  -- Both halves must go together: truncating the log while leaving the world
  -- populated would keep serving old tallies until the next restart, and
  -- resetting the world alone would have the next restart replay it all back.
  it "clears state and log together, leaving nothing to replay" $
    withTempLog $ \path -> do
      (store, sid) <- seeded (Just path)
      must (setPhase store sid choiceKey Live)
      must_ (recordResponse store (epoch 0) sid choiceKey (AnswerChoice (OptionKey "a")))

      report <- clearAll store
      clearedResponses report `shouldBe` 1
      clearedSessions report `shouldBe` 1
      clearedQuizzes report `shouldBe` 1

      readWorld store `shouldReturn` emptyWorld
      readFile path `shouldReturn` ""

      (reopened, again) <- openStore (Just path)
      replayedEvents again `shouldBe` 0
      readWorld reopened `shouldReturn` emptyWorld

  -- The property that makes surviving an auto-stop mid-lecture possible.
  it "reconstructs identical state by replaying its log" $
    withTempLog $ \path -> do
      (store, sid) <- seeded (Just path)
      must (setPhase store sid choiceKey Live)
      must_ (recordResponse store (epoch 0) sid choiceKey (AnswerChoice (OptionKey "a")))
      must_ (recordResponse store (epoch 1) sid choiceKey (AnswerChoice (OptionKey "b")))
      must (setPhase store sid choiceKey Closed)
      original <- readWorld store

      (reopened, report) <- openStore (Just path)
      restored <- readWorld reopened
      replaySkipped report `shouldBe` 0
      restored `shouldBe` original

  -- Regression: the store must not hold the log open, or GHC's per-process
  -- file lock makes GET /api/log — and so `quizctl pull` — fail with
  -- "resource busy" while the server is running.
  it "allows the log to be read back while the store is live" $
    withTempLog $ \path -> do
      (store, sid) <- seeded (Just path)
      must (setPhase store sid choiceKey Live)
      must_ (recordResponse store (epoch 0) sid choiceKey (AnswerChoice (OptionKey "a")))
      written <- readFile path
      length (lines written) `shouldBe` 5

  it "skips unreadable log lines rather than failing to start" $
    withTempLog $ \path -> do
      (store, _) <- seeded (Just path)
      _ <- readWorld store
      appendFile path "this is not json\n{\"event\":\"nonsense\"}\n"
      (_, report) <- openStore (Just path)
      replaySkipped report `shouldBe` 2

parsingSpec :: Spec
parsingSpec = do
  it "defaults feedback to after_close" $ do
    quiz <- expectParse (minimalQuiz [])
    quizFeedback quiz `shouldBe` FeedbackAfterClose

  it "reads an explicit feedback mode" $ do
    quiz <- expectParse (yaml ["quiz: q", "title: T", "feedback: immediate", "questions:"] <> choiceQuestion)
    quizFeedback quiz `shouldBe` FeedbackImmediate

  it "rejects an unknown feedback mode with the valid ones listed" $ do
    err <- expectFailure (yaml ["quiz: q", "title: T", "feedback: sometimes", "questions:"] <> choiceQuestion)
    err `shouldContainText` "after_close"

  it "keeps option keys rather than positions" $ do
    quiz <- expectParse (minimalQuiz [])
    case map questionBody (quizQuestions quiz) of
      [BodyChoice spec] ->
        map optionKey (choiceOptions spec) `shouldBe` [OptionKey "a", OptionKey "b"]
      other -> expectationFailure ("unexpected bodies: " <> show other)

  it "parses a scale range written as 1..5" $ do
    quiz <-
      expectParse . minimalQuiz $
        [ "  - key: c"
        , "    type: scale"
        , "    prompt: How sure?"
        , "    range: 1..5"
        ]
    case map questionBody (quizQuestions quiz) of
      [_, BodyScale spec] -> scaleRange spec `shouldBe` Range 1 5
      other -> expectationFailure ("unexpected bodies: " <> show other)

  it "parses integer-keyed scale labels" $ do
    quiz <-
      expectParse . minimalQuiz $
        [ "  - key: c"
        , "    type: scale"
        , "    prompt: How sure?"
        , "    range: 1..3"
        , "    labels:"
        , "      1: Low"
        , "      3: High"
        ]
    case map questionBody (quizQuestions quiz) of
      [_, BodyScale spec] ->
        scaleLabels spec `shouldBe` Map.fromList [(1, "Low"), (3, "High")]
      other -> expectationFailure ("unexpected bodies: " <> show other)

  it "parses a select range on a multi question" $ do
    quiz <-
      expectParse . minimalQuiz $
        [ "  - key: c"
        , "    type: multi"
        , "    prompt: Which?"
        , "    select: 1..2"
        , "    options:"
        , "      - { key: a, text: A }"
        , "      - { key: b, text: B }"
        ]
    case map questionBody (quizQuestions quiz) of
      [_, BodyMulti spec] -> multiSelect spec `shouldBe` Just (Range 1 2)
      other -> expectationFailure ("unexpected bodies: " <> show other)

  it "names the offending question when a body is malformed" $ do
    err <-
      expectFailure . minimalQuiz $
        [ "  - key: broken-one"
        , "    type: scale"
        , "    prompt: How sure?"
        , "    range: not-a-range"
        ]
    err `shouldContainText` "broken-one"

  it "lists the valid types for an unknown question type" $ do
    err <-
      expectFailure . minimalQuiz $
        [ "  - key: c"
        , "    type: wordcloud"
        , "    prompt: Hmm"
        ]
    err `shouldContainText` "choice"
    err `shouldContainText` "scale"

validationSpec :: Spec
validationSpec = do
  it "accepts a well-formed quiz" $ do
    quiz <- expectParse (minimalQuiz [])
    validateQuiz quiz `shouldBe` []

  it "reports duplicate question keys" $ do
    quiz <- expectParse (minimalQuiz (T.lines (TE.decodeUtf8 choiceQuestion)))
    problemsShouldMention quiz "duplicate question key"

  it "reports a correct answer that is not an option" $ do
    quiz <-
      expectParse . minimalQuiz $
        [ "  - key: c"
        , "    type: choice"
        , "    prompt: Pick"
        , "    correct: nope"
        , "    options:"
        , "      - { key: a, text: A }"
        , "      - { key: b, text: B }"
        ]
    problemsShouldMention quiz "not one of the options"

  it "reports a question with fewer than two options" $ do
    quiz <-
      expectParse . minimalQuiz $
        [ "  - key: c"
        , "    type: choice"
        , "    prompt: Pick"
        , "    options:"
        , "      - { key: a, text: A }"
        ]
    problemsShouldMention quiz "at least two options"

  it "reports a select maximum larger than the option count" $ do
    quiz <-
      expectParse . minimalQuiz $
        [ "  - key: c"
        , "    type: multi"
        , "    prompt: Which?"
        , "    select: 1..5"
        , "    options:"
        , "      - { key: a, text: A }"
        , "      - { key: b, text: B }"
        ]
    problemsShouldMention quiz "exceeds"

  it "reports a scale label outside the range" $ do
    quiz <-
      expectParse . minimalQuiz $
        [ "  - key: c"
        , "    type: scale"
        , "    prompt: How sure?"
        , "    range: 1..3"
        , "    labels:"
        , "      7: Off the end"
        ]
    problemsShouldMention quiz "falls outside"

  it "reports keys that would be ambiguous in a URL" $ do
    quiz <-
      expectParse . minimalQuiz $
        [ "  - key: Not A Key"
        , "    type: choice"
        , "    prompt: Pick"
        , "    options:"
        , "      - { key: a, text: A }"
        , "      - { key: b, text: B }"
        ]
    problemsShouldMention quiz "must match"

examplesSpec :: Spec
examplesSpec = do
  -- The template is meant to be copied and edited, so it must be a working
  -- quiz as shipped rather than only after the reader fixes it.
  it "ships quiz_template.yaml as a valid quiz" $ do
    parsed <- loadQuizFile "quiz_template.yaml"
    case parsed of
      Left err -> expectationFailure err
      Right quiz -> map formatProblem (validateQuiz quiz) `shouldBe` []

  -- The point of the template is the commented-out blocks, which nothing
  -- would otherwise check: they can drift out of step with the parser and
  -- stay wrong until someone copies one and it fails on them.
  it "offers commented-out blocks that are valid once uncommented" $ do
    raw <- readFile "quiz_template.yaml"
    let uncommented = unlines (map uncomment (lines raw))
    case decodeQuiz (TE.encodeUtf8 (T.pack uncommented)) of
      Left err -> expectationFailure ("uncommented template does not parse:\n" <> err)
      Right quiz -> do
        map formatProblem (validateQuiz quiz) `shouldBe` []
        -- Every type the tool supports should be there to copy.
        map (questionTypeName . questionBody) (quizQuestions quiz)
          `shouldBe` ["choice", "multi", "text", "scale", "grid"]

  it "reads a quiz written into a Markdown deck" $ do
    parsed <- loadQuizFile "slides/ethics-week4.md"
    case parsed of
      Left err -> expectationFailure err
      Right quiz -> do
        map formatProblem (validateQuiz quiz) `shouldBe` []
        quizSlug quiz `shouldBe` QuizSlug "ethics-week4"
        -- Questions come out in document order, which is the order they are
        -- asked in.
        map (unQuestionKey . questionKey) (quizQuestions quiz)
          `shouldBe` [ "transplant"
                     , "what-explains"
                     , "name-the-principle"
                     , "still-consequentialist"
                     ]

  -- The two authoring styles are one parser with two front ends, so a deck and
  -- the equivalent standalone file must give the identical quiz — otherwise
  -- what reaches the server would depend on how it was written down.
  it "gives the same quiz however it was written" $ do
    let embedded =
          TE.encodeUtf8 . T.pack $
            unlines
              [ "---"
              , "quiz: same"
              , "title: Same"
              , "---"
              , ""
              , "# A slide"
              , ""
              , "```quiz"
              , "key: pick"
              , "type: choice"
              , "prompt: Pick one"
              , "options:"
              , "  - { key: a, text: A }"
              , "  - { key: b, text: B }"
              , "```"
              ]
        standalone =
          yaml
            [ "quiz: same"
            , "title: Same"
            , "questions:"
            , "  - key: pick"
            , "    type: choice"
            , "    prompt: Pick one"
            , "    options:"
            , "      - { key: a, text: A }"
            , "      - { key: b, text: B }"
            ]
    decodeQuizMarkdown embedded `shouldBe` decodeQuiz standalone

  it "accepts a fence written in pandoc's attribute form" $ do
    let deck cls =
          TE.encodeUtf8 . T.pack $
            unlines
              [ "---", "quiz: f", "title: F", "---"
              , "``` " <> cls
              , "key: k"
              , "type: text"
              , "prompt: Say something"
              , "```"
              ]
    -- Bare, and both class orders — ```{.yaml .quiz} is what gets an editor to
    -- highlight the YAML, so it must work too.
    for_ ["quiz", "{.quiz}", "{.quiz .yaml}", "{.yaml .quiz}"] $ \cls ->
      case decodeQuizMarkdown (deck cls) of
        Left err -> expectationFailure (cls <> ": " <> err)
        Right q -> length (quizQuestions q) `shouldBe` 1

  it "says which fence is at fault when one will not parse" $ do
    let deck =
          TE.encodeUtf8 . T.pack $
            unlines
              [ "---", "quiz: f", "title: F", "---"
              , "```quiz"
              , "key: ok"
              , "type: text"
              , "prompt: Fine"
              , "```"
              , "```quiz"
              , "key: bad"
              , "  nested: [oops"
              , "```"
              ]
    case decodeQuizMarkdown deck of
      Right _ -> expectationFailure "expected the second fence to be rejected"
      Left err -> err `shouldSatisfy` ("quiz block 2" `isInfixOf`)

  it "parses and validates examples/ethics-week3.yaml" $ do
    parsed <- loadQuizFile "examples/ethics-week3.yaml"
    case parsed of
      Left err -> expectationFailure err
      Right quiz -> do
        map formatProblem (validateQuiz quiz) `shouldBe` []
        -- The example is also the fixture that proves every question type
        -- parses, so it should carry one of each.
        map questionTypeName (map questionBody (quizQuestions quiz))
          `shouldBe` ["choice", "multi", "text", "scale", "grid"]

-- | Strip the comment marker from a commented-out YAML line, leaving prose
-- comments alone.
--
-- The distinction has to be made on shape, because the template uses ordinary
-- @#@ comments for both — anything else would make it awkward for a reader to
-- uncomment a block with their editor. A line counts as commented-out YAML
-- when the @#@ is the first non-space character and what follows begins like
-- YAML: a list item, an inline map, or a bare @key:@.
--
-- \"Bare\" is doing real work there. Prose in this template says things like
-- @`select:` constrains how many...@, and a looser test that accepted any
-- early colon would uncomment that sentence into a line starting with a
-- backtick, which is not valid YAML at all.
uncomment :: String -> String
uncomment line = case break (== '#') line of
  (indent, '#' : rest)
    | all (== ' ') indent
    , looksLikeYaml (dropWhile (== ' ') rest) ->
        indent <> dropOneSpace rest
  _ -> line
  where
    -- Exactly one space, so the block's own indentation survives.
    dropOneSpace (' ' : r) = r
    dropOneSpace r = r

    looksLikeYaml r = take 2 r == "- " || take 1 r == "{" || isBareKey r

    isBareKey r = case break (== ':') r of
      (k, ':' : _) -> not (null k) && all keyChar k
      _ -> False

    keyChar c = isAsciiLower c || isDigit c || c == '_' || c == '-'

-- Store helpers -------------------------------------------------------------

choiceKey, textKey, scaleKey, gridKey :: QuestionKey
choiceKey = QuestionKey "a-question"
textKey = QuestionKey "say-something"
scaleKey = QuestionKey "how-sure"
gridKey = QuestionKey "rate-these"

storeQuiz :: Quiz
storeQuiz =
  Quiz
    { quizSlug = QuizSlug "test-quiz"
    , quizTitle = "Test"
    , quizFeedback = FeedbackAfterClose
    , quizQuestions =
        [ Question choiceKey "Pick one" $
            BodyChoice
              ( ChoiceSpec
                  [Option (OptionKey "a") "A", Option (OptionKey "b") "B"]
                  Nothing
              )
        , Question textKey "Say something" (BodyText (TextSpec 100))
        , Question scaleKey "How sure?" (BodyScale (ScaleSpec (Range 1 5) mempty))
        , Question gridKey "Rate these" $
            BodyGrid
              ( GridSpec
                  [Option (OptionKey "p") "P", Option (OptionKey "q") "Q"]
                  (Range 1 5)
                  mempty
              )
        ]
    }

-- | A store with the quiz pushed and a session created and active.
seeded :: Maybe FilePath -> IO (Store, SessionId)
seeded mPath = do
  (store, _) <- openStore mPath
  must (pushQuiz store (epoch 0) storeQuiz)
  session <- freshSession (epoch 0) (quizSlug storeQuiz) "test"
  must (createSession store session)
  pure (store, sessionId session)

-- | Assert that a store operation succeeded, discarding its result.
must_ :: IO (Either Text a) -> IO ()
must_ = void . must

-- | Assert that a store operation succeeded, reporting its message if not.
must :: IO (Either Text a) -> IO a
must act =
  act >>= \case
    Left err -> do
      expectationFailure ("store operation failed: " <> T.unpack err)
      error "unreachable"
    Right a -> pure a

activeOf :: Store -> IO SessionState
activeOf store = do
  world <- readWorld store
  case activeState world of
    Nothing -> do
      expectationFailure "no active session"
      error "unreachable"
    Just st -> pure st

questionNamed :: QuestionKey -> SessionState -> Question
questionNamed qkey st =
  case filter ((== qkey) . questionKey) (quizQuestions (stateQuiz st)) of
    (q : _) -> q
    [] -> error ("no question " <> show qkey)

secretOf :: Store -> SessionId -> IO Secret
secretOf store sid = do
  world <- readWorld store
  case Map.lookup sid (worldSessions world) of
    Just st -> pure (sessionSecret (stateSession st))
    Nothing -> do
      expectationFailure "session vanished"
      error "unreachable"

visibilityOf :: Store -> QuestionKey -> IO [Bool]
visibilityOf store qkey = do
  st <- activeOf store
  pure (map responseVisible (responsesFor qkey st))

epoch :: Integer -> UTCTime
epoch = posixSecondsToUTCTime . fromInteger

withTempLog :: (FilePath -> IO a) -> IO a
withTempLog k = withSystemTempDirectory "quiz-store" (k . (</> "responses.jsonl"))

-- Helpers -------------------------------------------------------------------

yaml :: [Text] -> ByteString
yaml = TE.encodeUtf8 . T.unlines

-- | A parseable quiz containing one choice question, plus whatever extra
-- question lines the caller appends.
minimalQuiz :: [Text] -> ByteString
minimalQuiz extra =
  yaml ["quiz: q", "title: T", "questions:"] <> choiceQuestion <> yaml extra

choiceQuestion :: ByteString
choiceQuestion =
  yaml
    [ "  - key: a-question"
    , "    type: choice"
    , "    prompt: Pick one"
    , "    options:"
    , "      - { key: a, text: A }"
    , "      - { key: b, text: B }"
    ]

expectParse :: ByteString -> IO Quiz
expectParse input = case decodeQuiz input of
  Left err -> do
    expectationFailure ("expected a parse, got error:\n" <> err)
    error "unreachable"
  Right quiz -> pure quiz

expectFailure :: ByteString -> IO String
expectFailure input = case decodeQuiz input of
  Left err -> pure err
  Right quiz -> do
    expectationFailure ("expected a parse error, got: " <> show quiz)
    error "unreachable"

shouldContainText :: String -> Text -> Expectation
shouldContainText haystack needle =
  haystack `shouldSatisfy` (T.unpack needle `isInfixOf`)

problemsShouldMention :: Quiz -> Text -> Expectation
problemsShouldMention quiz needle = do
  let rendered = map (T.unpack . formatProblem) (validateQuiz quiz)
  rendered `shouldSatisfy` any (T.unpack needle `isInfixOf`)
