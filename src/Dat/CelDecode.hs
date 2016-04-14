-- https://github.com/doggan/diablo-file-formats

module Dat.CelDecode (DecodedCel(..), CelColor, getCelFrameDecoder) where

import Control.Monad (replicateM)
import Dat.Utils
import Data.Binary.Strict.Get
import Data.List (foldl')

import qualified Data.ByteString as BS

-- palette idx, Nothing for transparent
type CelColor = Maybe Word8

data DecodedCel = DecodedCel { decodedCelWidth :: Int
                             , decodedCelHeight :: Int
                             , decodedCelColors :: [CelColor] }

type FrameDecoder = ByteString -> Int -> Int -> DecodedCel

decodeFrameType0 :: FrameDecoder
decodeFrameType0 frameData width height = DecodedCel width height colors
  where colors = fmap Just $ BS.unpack frameData

decodeFrameType1 :: FrameDecoder
decodeFrameType1 frameData width height = DecodedCel width height colors
  where
    colors = let (res, _) = runGet readColors frameData
             in either undefined id res
    readColors :: Get [CelColor]
    readColors = do
      chunkSize <- fmap fromIntegral getWord8
      chunk <- if chunkSize >= 128
               then replicateM (256 - chunkSize) (return Nothing)
               else replicateM chunkSize (getWord8 >>= return . Just)
      empty <- isEmpty
      fmap (chunk ++) (if empty then return [] else readColors)

decodeFrameType2 :: FrameDecoder
decodeFrameType2 =
  decodeFrameTypeHelper decodeCounts (\i -> if i `mod` 2 == 0 then 0 else 2) decodeLineTransparencyLeft
  where decodeCounts = [0, 4, 4, 8, 8, 12, 12, 16, 16, 20, 20, 24, 24, 28, 28, 32, 32, 32, 28, 28, 24, 24, 20, 20, 16, 16, 12, 12, 8, 8, 4, 4]

decodeFrameType3 :: FrameDecoder
decodeFrameType3 =
  decodeFrameTypeHelper decodeCounts (\i -> if i `mod` 2 == 0 then 0 else 2) decodeLineTransparencyRight
  where decodeCounts = [0, 4, 4, 8, 8, 12, 12, 16, 16, 20, 20, 24, 24, 28, 28, 32, 32, 32, 28, 28, 24, 24, 20, 20, 16, 16, 12, 12, 8, 8, 4, 4]


decodeFrameType4 :: FrameDecoder
decodeFrameType4 =
  decodeFrameTypeHelper decodeCounts zeroCount decodeLineTransparencyLeft
  where
    decodeCounts = [4, 4, 8, 8, 12, 12, 16, 16, 20, 20, 24, 24, 28, 28, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32]
    zeroCount i = if elem i [0,2,4,6,8,10,12,14] then 2 else 0

decodeFrameType5 :: FrameDecoder
decodeFrameType5 =
  decodeFrameTypeHelper decodeCounts zeroCount decodeLineTransparencyRight
  where
    decodeCounts = [4, 4, 8, 8, 12, 12, 16, 16, 20, 20, 24, 24, 28, 28, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32]
    zeroCount i = if elem i [0,2,4,6,8,10,12,14] then 2 else 0

type TransparentLineDecoder = ByteString -> Int -> Int -> Int -> [CelColor]

decodeFrameTypeHelper :: [Int] -> (Int -> Int) -> TransparentLineDecoder -> ByteString -> Int -> Int -> DecodedCel
decodeFrameTypeHelper decodeCounts zeroCount decodeLine frameData width height = DecodedCel width height colors
  where
    (_, _, colors) = foldl' decode (0 :: Int, 0, []) decodeCounts
    decode (i, offset, acc) decodeCount =
      (i + 1, offset + decodeCount, acc ++ decodeLine frameData offset decodeCount (zeroCount i))

decodeLineTransparencyLeft :: TransparentLineDecoder
decodeLineTransparencyLeft frameData frameReadOffset decodeCount zeroCount =
  implicitTransparentPixels ++ explicitTransparentPixels ++ explicitRegularPixels
  where
    implicitTransparentPixels = replicate (32 - decodeCount) Nothing
    explicitTransparentPixels = replicate zeroCount Nothing
    explicitRegularPixels     = fmap getColor [zeroCount..decodeCount-1]
    getColor i = Just $ index frameData (frameReadOffset + i)

decodeLineTransparencyRight :: TransparentLineDecoder
decodeLineTransparencyRight frameData frameReadOffset decodeCount zeroCount =
  explicitRegularPixels ++ explicitTransparentPixels ++ implicitTransparentPixels
  where
    regularCount = decodeCount - zeroCount
    explicitRegularPixels     = fmap getColor [0..regularCount-1]
    explicitTransparentPixels = replicate zeroCount Nothing
    implicitTransparentPixels = replicate (32 - decodeCount) Nothing
    getColor i = Just $ index frameData (frameReadOffset + i)

-- decodeFrameType6 :: FrameDecoder
-- decodeFrameType6 frameData width height = DecodedCel width height (fromList colors)
--   where
--     colors = let (res, _) = runGet (skip headerSizeSkip >>= \_ -> readColors) frameData
--              in either undefined id res
--     headerSizeSkip = 10
--     readColors :: Get [CelColor]
--     readColors = do
--       chunkSize <- getWord8
--       chunk <- if chunkSize > 65 && chunkSize < 128
--                then do
--                  col <- getColor
--                  return $ fmap (const col) [1..chunkSize]
--                else mapM (if chunkSize < 128
--                      then (const $ return transparent)
--                      else const getColor) [1..chunkSize]
--       fmap (chunk ++) readColors
--     getColor = do
--       idx <- getWord8
--       return $ extendColor $ Pal.getColor idx

-- Returns true if the image is a plain 32x32.
isType0 :: String -> Int -> Bool
isType0 celName frameNum =
  -- These special frames are type 1.
  case celName of
    "l1" -> not $ oneOf [148, 159, 181, 186, 188]
    "l2" -> not $ oneOf [47, 1397, 1399, 1411]
    "l4" -> not $ oneOf [336, 639]
    "town" -> not $ oneOf [2328, 2367, 2593]
    _ -> True
  where
    oneOf :: [Int] -> Bool
    oneOf nums = any (== frameNum) nums

-- Returns true if the image is a less-than (<) shape.
isType2or4 :: ByteString -> Bool
isType2or4 frameData = not $ any check [0, 1, 8, 9, 24, 25, 48, 49, 80, 81, 120, 121, 168, 169, 224, 225]
  where
    check zeroPos = index frameData zeroPos /= 0

-- Returns true if the image is a greater-than (>) shape.
isType3or5 :: ByteString -> Bool
isType3or5 frameData = not $ any check [2, 3, 14, 15, 34, 35, 62, 63, 98, 99, 142, 143, 194, 195, 254, 255]
  where
    check zeroPos = index frameData zeroPos /= 0

getCelFrameDecoder :: String -> ByteString -> Int -> FrameDecoder
getCelFrameDecoder celName frameData frameNum =
  if elem celName ["l1", "l2", "l3", "l4", "town"]
  then case (BS.length frameData) of
         0x400 -> if isType0 celName frameNum then decodeFrameType0 else decodeFrameType1
         0x220 -> if isType2or4 frameData
                  then decodeFrameType2 else
                    if isType3or5 frameData then decodeFrameType3 else decodeFrameType1
         0x320 -> if isType2or4 frameData then decodeFrameType4 else
                    if isType3or5 frameData then decodeFrameType5 else decodeFrameType1
         _ -> decodeFrameType1
  else decodeFrameType1
