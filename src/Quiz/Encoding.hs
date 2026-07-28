-- | Text encoding must not depend on the environment.
--
-- GHC picks its default encoding from the locale. A container with no @LANG@
-- set therefore gets ASCII, and writing so much as an em dash to stdout dies
-- with @commitBuffer: invalid argument@. Quiz prompts and student free-text
-- answers are full of curly quotes, dashes, and emoji, so every entry point
-- must pin UTF-8 before doing any IO.
module Quiz.Encoding
  ( forceUtf8
  ) where

import GHC.IO.Encoding (setLocaleEncoding, utf8)
import System.IO (hSetEncoding, stderr, stdout)

-- | Pin UTF-8 for stdout, stderr, and any handle opened later. Call this as
-- the first action in @main@.
forceUtf8 :: IO ()
forceUtf8 = do
  -- Covers files opened after this point, including the response log.
  setLocaleEncoding utf8
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
