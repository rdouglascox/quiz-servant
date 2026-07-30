-- | QR codes for the one URL students actually have to get right: the join
-- address.
--
-- Rendered ourselves in two forms — inline SVG for slides and the presenter
-- page, Unicode half-blocks for the terminal — rather than pulling in an
-- image codec. @qrcode-core@ hands back a bit matrix and nothing more is
-- needed: an @<img>@ pointing at a rendered PNG could not inherit the deck's
-- colour any more than an iframe could, which is exactly the problem the rest
-- of this server's embedding was built to avoid.
module Quiz.Qr
  ( qrMatrix
  , qrSvg
  , qrAnsi
  ) where

import Codec.QRCode
import Data.Text (Text)
import Data.Text qualified as T

-- | The QR modules for a piece of text — @True@ is a dark module — or
-- 'Nothing' if it could not be encoded at all. Unreachable in practice: that
-- only happens for input far longer than any URL this server prints.
qrMatrix :: Text -> Maybe [[Bool]]
qrMatrix = fmap (toMatrix True False) . encodeText (defaultQRCodeOptions Q) Iso8859_1

-- | The blank border QR readers rely on to find the code at all, in modules.
quietZone :: Int
quietZone = 4

-- | A complete @\<svg\>@ element, deliberately with no @width@\/@height@
-- attribute — only a @viewBox@ — so the page sizes it with ordinary CSS, the
-- same way it sizes everything else here.
--
-- Modules are filled with @currentColor@ rather than a literal colour, so the
-- code inherits the deck's ink and needs no light\/dark handling of its own —
-- the same trick the tally bars use. A dark deck yields light-on-dark
-- modules, which scanners read exactly as readily as the reverse; there is no
-- need to force a background behind it.
qrSvg :: [[Bool]] -> Text
qrSvg rows =
  "<svg viewBox=\"0 0 "
    <> side
    <> " "
    <> side
    <> "\" shape-rendering=\"crispEdges\">"
    <> "<g fill=\"currentColor\">"
    <> T.concat
      [ rect x y
      | (y, row) <- zip [0 :: Int ..] rows
      , (x, dark) <- zip [0 :: Int ..] row
      , dark
      ]
    <> "</g></svg>"
  where
    n = length rows
    side = tshow (n + 2 * quietZone)
    rect x y =
      "<rect x=\""
        <> tshow (x + quietZone)
        <> "\" y=\""
        <> tshow (y + quietZone)
        <> "\" width=\"1\" height=\"1\"/>"

-- | Unicode half-blocks, two module rows per character row — a terminal cell
-- is roughly twice as tall as it is wide, so pairing rows keeps the printed
-- code close to square.
--
-- Uses the terminal's own default foreground and background, no ANSI colour
-- codes: a dark module is ink, a light module is a plain space (the
-- background shows through), so this reads correctly in both a light and a
-- dark terminal theme without asking which — the same policy as the SVG.
qrAnsi :: [[Bool]] -> Text
qrAnsi rows0 = T.unlines (map rowText (pairUp padded))
  where
    n = length rows0
    width = n + 2 * quietZone
    blankRow = replicate width False
    padRow r = replicate quietZone False <> r <> replicate quietZone False
    padded = replicate quietZone blankRow <> map padRow rows0 <> replicate quietZone blankRow

    pairUp (a : b : rest) = (a, b) : pairUp rest
    pairUp [a] = [(a, blankRow)]
    pairUp [] = []

    rowText (top, bot) = T.pack (zipWith cellChar top bot)
    cellChar True True = '█'
    cellChar True False = '▀'
    cellChar False True = '▄'
    cellChar False False = ' '

tshow :: (Show a) => a -> Text
tshow = T.pack . show
