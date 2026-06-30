{-# LANGUAGE BangPatterns #-}

import Control.Concurrent.Async (mapConcurrently)
-- Импортируем Control.Parallel.Strategies для гарантированного параллелизма
import Control.Parallel.Strategies (withStrategy, parListChunk, rdeepseq)
import qualified Data.Vector.Storable as V
import qualified Numeric.FFT.Vector.Invertible as FFT
import Data.Complex
import System.IO
import Data.List (foldl')
import GHC.Conc (numCapabilities)
import System.Environment (getArgs)
import Text.Printf (printf)

type ComplexDouble = Complex Double

prepareCoefficients :: Double -> Int -> Int -> V.Vector ComplexDouble
prepareCoefficients !t0 !nMin !nMax = V.generate (nMax - nMin + 1) $ \idx ->
    let n   = fromIntegral (nMin + idx)
        phi = -t0 * log n
        baseTerm = (1.0 / sqrt n) :+ 0.0
        phaseShift = exp (0.0 :+ phi)
    in baseTerm * phaseShift

evalBlockOD :: Double -> Double -> Int -> V.Vector Double
evalBlockOD !t0 !deltaT !samples = 
    let nMax = floor (sqrt ((t0 + deltaT) / (2 * pi)))
        nMin = 1
        coeffs = prepareCoefficients t0 nMin nMax
        fftResult = FFT.run FFT.dft coeffs
        theta !t = (t / 2) * log (t / (2 * pi)) - (t / 2) - (pi / 8)
    in V.imap (\idx complexVal ->
        let t = t0 + (fromIntegral idx * (deltaT / fromIntegral samples))
            realPartVal = realPart (complexVal * exp (0.0 :+ theta t))
        in 2 * realPartVal
       ) fftResult

findZerosInVector :: Double -> Double -> V.Vector Double -> [Double]
findZerosInVector !t0 !deltaT !vals = go 0 []
  where
    !len = V.length vals
    !step = deltaT / fromIntegral len
    go !i !acc
      | i >= len - 1 = reverse acc
      | otherwise =
          let v1 = vals V.! i
              v2 = vals V.! (i + 1)
              isZero = (v1 > 0 && v2 < 0) || (v1 < 0 && v2 > 0)
              tZero  = t0 + (fromIntegral i * step) + (step / 2)
          in if isZero 
             then go (i + 1) (tZero : acc)
             else go (i + 1) acc

-- | ОПТИМИЗАЦИЯ: Строгий параллельный конвейер без ленивых задержек
processPipeline :: Double -> Double -> Double -> IO [Double]
processPipeline !globalStart !globalEnd !blockSize = do
    let !blocks = [ (t, min globalEnd (t + blockSize)) 
                  | t <- [globalStart, globalStart + blockSize .. globalEnd - 1] ]
        samplesPerBlock = 1048576 
    
    -- Вычисляем блоки строго параллельными чанками, заставляя GHC нагружать все ядра сразу
    let !chunksOfZeros = withStrategy (parListChunk 8 rdeepseq) $ map (\(s, e) ->
                           findZerosInVector s (e - s) (evalBlockOD s (e - s) samplesPerBlock)
                         ) blocks
                         
    return $ concat chunksOfZeros

main :: IO ()
main = do
    args <- getArgs
    case args of
        [blockNumStr, startStr, endStr] -> do
            let tStart    = read startStr :: Double
                tEnd      = read endStr :: Double
                blockSize = 10000.0 -- Уменьшили размер подблока для лучшей балансировки ядер
            
            allZeros <- processPipeline tStart tEnd blockSize
            
            let (!totalCount, !last10) = foldl' (\(!cnt, !acc) z -> 
                    (cnt + 1, drop (if length acc >= 10 then 1 else 0) acc ++ [z])) (0, []) allZeros :: (Int, [Double])
            
            let filePath = "riemann_chunks_summary.csv"
            withFile filePath AppendMode $ \handle -> do
                hPutStrLn handle $ blockNumStr ++ ";" ++ startStr ++ ";" ++ endStr ++ ";" ++ show totalCount
                
            putStrLn "========================================"
            printf "Блок №%s успешно обработан.\n" blockNumStr
            printf "Интервал: от %.1f до %.1f\n" tStart tEnd
            printf "Найдено нулей в этом батче: %d\n" totalCount
            printf "Последние 10 найденных мнимых частей:\n"
            mapM_ (\z -> printf "  t = %.4f\n" z) last10
            putStrLn "========================================"
            
        _ -> putStrLn "Ошибка: Передайте аргументы: ./zeta_stress <номер_блока> <tStart> <tEnd>"
