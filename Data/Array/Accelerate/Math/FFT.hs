{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators       #-}
-- |
-- Module      : Data.Array.Accelerate.Math.FFT
-- Copyright   : [2012] Manuel M T Chakravarty, Gabriele Keller, Trevor L. McDonell
-- License     : BSD3
--
-- Maintainer  : Manuel M T Chakravarty <chak@cse.unsw.edu.au>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)
--
-- Computation of a Discrete Fourier Transform using the Cooley-Tuckey
-- algorithm. The time complexity is O(n log n) in the size of the input.
--
-- This uses a naïve divide-and-conquer algorithm whose absolute performance is
-- appalling.
--
module Data.Array.Accelerate.Math.FFT (

  Mode(..),
  fft1D, fft1D',
  fft2D, fft2D',
  fft3D, fft3D',
  fft

) where

import Prelude                                  as P
import Data.Array.Accelerate                    as A
import Data.Array.Accelerate.Array.Sugar        ( showShape )
import Data.Array.Accelerate.Math.Complex
import Data.Bits


data Mode = Forward | Reverse | Inverse
  deriving (Eq, Show)

isPow2 :: Int -> Bool
isPow2 x = x .&. (x-1) == 0

signOfMode :: IsFloating a => Mode -> a
signOfMode m
  = case m of
      Forward   -> -1
      Reverse   ->  1
      Inverse   ->  1


-- Vector Transform
-- ----------------
--
-- Discrete Fourier Transform of a vector. Array dimensions must be powers of
-- two else error.
--
fft1D :: (Elt e, IsFloating e)
      => Mode
      -> Vector (Complex e)
      -> Acc (Vector (Complex e))
fft1D mode vec
  = let Z :. len = arrayShape vec
    in
    fft1D' mode len (use vec)

fft1D' :: forall e. (Elt e, IsFloating e)
       => Mode
       -> Int
       -> Acc (Vector (Complex e))
       -> Acc (Vector (Complex e))
fft1D' mode len vec
  = let sign    = signOfMode mode :: e
        scale   = P.fromIntegral len
        vec'    = fft sign Z len vec
    in
    if P.not (isPow2 len)
       then error $ unlines
              [ "Data.Array.Accelerate.FFT: fft1D"
              , "  Array dimensions must be powers of two, but are: " ++ showShape (Z:.len) ]

       else case mode of
                 Inverse -> A.map (/scale) vec'
                 _       -> vec'


-- Matrix Transform
-- ----------------
--
-- Discrete Fourier Transform of a matrix. Array dimensions must be powers of
-- two else error.
--
fft2D :: (Elt e, IsFloating e)
      => Mode
      -> Array DIM2 (Complex e)
      -> Acc (Array DIM2 (Complex e))
fft2D mode arr
  = let Z :. height :. width = arrayShape arr
    in
    fft2D' mode width height (use arr)


fft2D' :: forall e. (Elt e, IsFloating e)
       => Mode
       -> Int   -- ^ width
       -> Int   -- ^ height
       -> Acc (Array DIM2 (Complex e))
       -> Acc (Array DIM2 (Complex e))
fft2D' mode width height arr
  = let sign    = signOfMode mode :: e
        scale   = P.fromIntegral (width * height)
        arr'    = A.transpose . fft sign (Z:.width)  height
                $ A.transpose . fft sign (Z:.height) width
                $ arr
    in
    if P.not (isPow2 width && isPow2 height)
       then error $ unlines
              [ "Data.Array.Accelerate.FFT: fft2D"
              , "  Array dimensions must be powers of two, but are: " ++ showShape (Z:.height:.width) ]

       else case mode of
                 Inverse -> A.map (/scale) arr'
                 _       -> arr'


-- Cube Transform
-- --------------
--
-- Discrete Fourier Transform of a 3D array. Array dimensions must be power of
-- two else error.
--
fft3D :: (Elt e, IsFloating e)
      => Mode
      -> Array DIM3 (Complex e)
      -> Acc (Array DIM3 (Complex e))
fft3D mode arr
  = let Z :. depth :. height :. width = arrayShape arr
    in
    fft3D' mode width height depth (use arr)


fft3D' :: forall e. (Elt e, IsFloating e)
       => Mode
       -> Int   -- ^ width
       -> Int   -- ^ height
       -> Int   -- ^ depth
       -> Acc (Array DIM3 (Complex e))
       -> Acc (Array DIM3 (Complex e))
fft3D' mode width height depth arr
  = let sign    = signOfMode mode :: e
        scale   = P.fromIntegral (width * height)
        arr'    = rotate3D . fft sign (Z:.width :.depth)  height
                $ rotate3D . fft sign (Z:.height:.width)  depth
                $ rotate3D . fft sign (Z:.depth :.height) width
                $ arr
    in
    if P.not (isPow2 width && isPow2 height && isPow2 depth)
       then error $ unlines
              [ "Data.Array.Accelerate.FFT: fft3D"
              , "  Array dimensions must be powers of two, but are: " ++ showShape (Z:.depth:.height:.width) ]

       else case mode of
                 Inverse -> A.map (/scale) arr'
                 _       -> arr'



rotate3D :: Elt e => Acc (Array DIM3 e) -> Acc (Array DIM3 e)
rotate3D arr
  = backpermute (swap (shape arr)) swap arr
  where
    swap :: Exp DIM3 -> Exp DIM3
    swap ix =
      let Z :. m :. k :. l = unlift ix  :: Z :. Exp Int :. Exp Int :. Exp Int
      in  lift $ Z :. k :. l :. m


-- Rank-generalised Cooley-Tuckey DFT
--
-- We require the innermost dimension be passed as a Haskell value because we
-- can't do divide-and-conquer recursion directly in the meta-language.
--
fft :: forall sh e. (Slice sh, Shape sh, IsFloating e, Elt e)
    => e
    -> sh
    -> Int
    -> Acc (Array (sh:.Int) (Complex e))
    -> Acc (Array (sh:.Int) (Complex e))
fft sign sh sz arr = go sz 0 1
  where
    go :: Int -> Int -> Int -> Acc (Array (sh:.Int) (Complex e))
    go len offset stride
      | len == 2
      = A.generate (constant (sh :. len)) swivel

      | otherwise
      = combine len
          (go (len `div` 2) offset            (stride * 2))
          (go (len `div` 2) (offset + stride) (stride * 2))

      where
        swivel ix =
          let sh' :. sz' = unlift ix :: Exp sh :. Exp Int
          in
          sz' ==* 0 ? ( (arr ! lift (sh' :. offset)) + (arr ! lift (sh' :. offset + stride))
          {-  ==* 1-} , (arr ! lift (sh' :. offset)) - (arr ! lift (sh' :. offset + stride)) )

        combine len' evens odds =
          let odds' = A.generate (A.shape odds) (\ix -> twiddle len' (indexHead ix) * odds!ix)
          in
          append (A.zipWith (+) evens odds') (A.zipWith (-) evens odds')

        twiddle n' i' =
          let n = P.fromIntegral n'
              i = A.fromIntegral i'
              k = 2*pi*i/n
          in
          lift ( cos k, A.constant sign * sin k )


-- Append two arrays. Doesn't do proper bounds checking or intersection...
--
append
    :: forall sh e. (Slice sh, Shape sh, Elt e)
    => Acc (Array (sh:.Int) e)
    -> Acc (Array (sh:.Int) e)
    -> Acc (Array (sh:.Int) e)
append xs ys
  = let sh :. n = unlift (shape xs)     :: Exp sh :. Exp Int
        _  :. m = unlift (shape ys)     :: Exp sh :. Exp Int
    in
    generate (lift (sh :. n+m))
             (\ix -> let sz :. i = unlift ix :: Exp sh :. Exp Int
                     in  i <* n ? (xs ! lift (sz:.i), ys ! lift (sz:.i-n) ))

