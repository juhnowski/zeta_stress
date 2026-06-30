import Control.Parallel.Strategies (using, parListChunk, rdeepseq)
import Data.Complex
import GHC.Conc (numCapabilities)

-- Вычисление эта-функции Дирихле для s = 0.5 + it
etaFloat :: Double -> Complex Double
etaFloat t = sum [ term n | n <- [1..80000] ]
  where
    s = 0.5 :+ t
    term n = (if odd n then 1 else -1) / (fromIntegral n ** s)

isZeroApprox :: Complex Double -> Bool
isZeroApprox (r :+ i) = abs r < 1e-6 && abs i < 1e-6

-- Явно указываем типы аргументов, чтобы GHC не путался
processChunk :: (Double, Double, Double) -> Int
processChunk (start, end, step) = 
    length [ t | t <- [start, start+step .. end], isZeroApprox (etaFloat t) ]

main :: IO ()
main = do
  putStrLn $ "NixOS рантайм видит ядер: " ++ show numCapabilities
  putStrLn "Генерация терабайтной структуры данных в куче..."
  
  -- Масштабируем количество чанков
  let totalChunks = 4096
      chunks :: [(Double, Double, Double)]
      chunks = [ (fromIntegral i * 2000.0, fromIntegral (i+1) * 2000.0, 0.00002) | i <- [1..totalChunks] ]
      
      -- Применяем процесс вычисления К СПИСКУ, а затем форсируем глубокий параллелизм через rdeepseq
      results = map processChunk chunks `using` parListChunk 32 rdeepseq
      totalFound = sum results
      
  putStrLn $ "Вычисления успешно завершены. Найдено точек: " ++ show totalFound
