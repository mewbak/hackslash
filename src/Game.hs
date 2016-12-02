{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE OverloadedStrings #-}
module Game where

import Control.Monad (void)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Fix (MonadFix)
import GHC.Word (Word32)
import Linear.V2
import Linear.Affine
import Reflex
import Reflex.SDL.Event
import Reflex.SDL.Host
import SDL hiding (Renderer, Event, trace)

import Animation
import Freeablo
import Types

import Debug.Trace hiding (traceEvent)
import Reflex.Dynamic (traceDyn)

ticksPerSecond :: Int
ticksPerSecond = 60

data Game t = Game {
  gameCameraPos :: Behavior t Coord,
  gameMonsters :: [Monster t]
}

type Health = Int

data AnimationFrame = AnimationFrame
  { animationFrameIdx :: Int
  , animationFrameMoveDist :: MoveDist }

data Monster t = Monster
  { monsterAnim :: Dynamic t Animation
  , monsterAnimationFrame :: Dynamic t AnimationFrame
  , monsterPosition :: Dynamic t Coord
  , monsterDirection :: Dynamic t Direction
  , monsterDie :: Event t () }

data Input t = Input
  { inputTick :: Event t Word32 }

type Path = [Coord]

every :: (Reflex t, MonadHold t m, MonadFix m, Integral n)
      => n
      -> Event t a
      -> m (Event t a)
every n e = do
  count <- accum (+) 0 (1 <$ e)
  pure $ attachWithMaybe (\c v -> if c `mod` n == 0 then Just v else Nothing) count e

movement :: (Reflex t, MonadHold t m, MonadFix m)
         => Input t
         -> Coord
         -> Animation
         -> Event t [Coord] -- TODO: last elem is dropped
         -> m (Dynamic t (Coord, Direction), Dynamic t AnimationFrame)
movement Input{..} initialPos Animation{animationLength} path = do
  let speed = animationLength -- meaning one frame per one tick
  moved <- every speed inputTick
  coords <- accum (flip ($)) [] $ mergeWith (.) [(\path _ -> pathWithDirections path) <$> path -- new path arrives, replace the coords
                                                , drop 1 <$ moved -- on move, drop the coord
                                                ]
  let posDir = head <$> ffilter (not . null) (tag coords moved)
  posDir <- holdDyn (initialPos, DirN) posDir
  frameTick <- every (speed `div` animationLength) inputTick
  frame <- accum (\acc f -> f acc `mod` animationLength) 0 $ leftmost [ const 0 <$ moved
                                                                      , (+1) <$ frameTick]
  -- freeablo wants it to be a percentage of the way towards next square
  let moveDist = (\f -> f * 100 `div` animationLength) <$> frame
  pure (posDir, AnimationFrame <$> frame <*> (MoveDist <$> moveDist))
  where
    pathWithDirections path =
      ffor (zip path (drop 1 path)) $ \(from, to) -> (from, calcDir from to)
    calcDir from to =
      let (P (V2 x y)) = to - from in
      case (x, y) of
        (-1, -1) -> DirN
        (0, -1) -> DirNE
        (1,-1) -> DirE
        (1, 0) -> DirSE
        (1, 1) -> DirS
        (0, 1) -> DirSW
        (-1, 1) -> DirW
        (-1, 0) -> DirNW

testMonster :: (Reflex t, MonadFix m, MonadHold t m, MonadIO m)
            => SpriteManager
            -> Input t
            -> m (Monster t)
testMonster spriteManager input@Input{..} = do
  animSet <- loadMonsterAnimSet spriteManager "fatc"
  let initialCoord = (P (V2 60 70))
      initialPos = initialCoord
      testPath = [initialCoord + P (V2 i 0) | i <- [0..10]]
  testPath <- every 60 $ testPath <$ inputTick
  (posDir, animFrame) <- movement input initialPos (animSetWalk animSet) testPath
  let (pos, dir) = splitDynPure posDir
  pure $ Monster (constDyn (animSetWalk animSet)) animFrame pos dir never

data GameState = GameState {
  gameStateCameraPos :: Coord
}

newGame = GameState { gameStateCameraPos = P (V2 15 29) }

screenScroll :: (Reflex t, MonadHold t m, MonadFix m)
             => Coord
             -> Event t Keycode
             -> m (Behavior t Coord)
screenScroll initialPos keyPress = accum (\pos d -> pos + P d) initialPos cameraMove
  where
    moveLeft   = V2 (-1) 1    <$ ffilter (== KeycodeLeft) keyPress
    moveRight  = V2 1 (-1)    <$ ffilter (== KeycodeRight) keyPress
    moveUp     = V2 (-1) (-1) <$ ffilter (== KeycodeUp) keyPress
    moveDown   = V2 1 1       <$ ffilter (== KeycodeDown) keyPress
    cameraMove = leftmost [moveLeft, moveRight, moveUp, moveDown]

hookLevelObjects :: (PerformEvent t m, MonadSample t (Performable m), MonadIO (Performable m), MonadIO m)
                 => [Monster t]
                 -> m LevelObjects
hookLevelObjects monsters = do
  levelObjects <- createLevelObjects
  traverse (updateObject levelObjects) monsters
  pure levelObjects
  where
    updateObject objs Monster{..} = do
      let bPos = current monsterPosition -- so that we refer to position before update
          bAnim = current monsterAnim
          animUpdate = (,) <$> monsterDirection <*> monsterAnimationFrame
          posFrame = attach bPos (updated animUpdate)
      performEvent_ $
        (\(pos, (Direction dir, AnimationFrame frame dist)) -> do
            Animation spriteGroup animLength <- sample bAnim
            spriteCacheIndex <- getSpriteCacheIndex spriteGroup
            let to = followDir pos (Direction dir)
            updateLevelObject objs pos spriteCacheIndex (frame + dir * animLength) to dist)
        <$> posFrame
      let fromTo = attach bPos (updated monsterPosition)
      performEvent_ $ uncurry (moveLevelObject objs) <$> fromTo

game :: SpriteManager -> Level -> SDLApp t m
game spriteManager level sel = do
  let keyPress = fmap (keysymKeycode . keyboardEventKeysym) .
                 ffilter ((== Pressed) . keyboardEventKeyMotion) .
                 select sel $
                 SDLKeyboard
      eQuit = void $ ffilter (== KeycodeEscape) keyPress
      tick = select sel SDLTick
  cameraPos <- screenScroll (P (V2 55 65)) keyPress
  monster <- testMonster spriteManager (Input tick)
  let monsters = [monster]
  let game' = Game cameraPos monsters
  levelObjects <- hookLevelObjects monsters
  performEvent_ $ renderGame spriteManager level levelObjects game' <$ tick
  performEvent_ $ liftIO quit <$ eQuit
  return eQuit

-- need to figure out correct monad stack, this looks tedious with all the liftIO
renderGame :: (Reflex t, MonadSample t m, MonadIO m)
           => SpriteManager
           -> Level
           -> LevelObjects
           -> Game t
           -> m ()
renderGame spriteManager level levelObjects Game{..} = do
  cameraPos@(P (V2 x y)) <- sample gameCameraPos
  renderFrame spriteManager level levelObjects cameraPos
