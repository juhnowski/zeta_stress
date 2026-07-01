{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

import Control.Concurrent.Async (mapConcurrently)
import Control.Parallel.Strategies (withStrategy, parListChunk, rdeepseq)
import qualified Data.Vector.Storable as V
import qualified Numeric.FFT.Vector.Invertible as FFT
import Data.Complex
import System.IO
import Data.List (foldl')
import GHC.Conc (numCapabilities)
import System.Environment (getArgs)
import Text.Printf (printf)
import Control.Monad (zipWithM_) -- Обязательно для последовательной индексированной отправки

-- Импорты для работы с InfluxDB HTTP API
import qualified Network.Wreq as W
import Control.Lens ((&), (.~))
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy.Char8 as BL
import Network.HTTP.Client (defaultManagerSettings, newManager)

type ComplexDouble = Complex Double

-- Собственная реализация разбиения списка на чанки без внешних зависимостей
chunksOf :: Int -> [a] -> [[a]]
chunksOf _ [] = []
chunksOf n xs = let (first, rest) = splitAt n xs in first : chunksOf n rest

-- | 1. Математическое ядро: подготовка коэффициентов с Zero Padding до размера FFT-окна
prepareCoefficients :: Int -> Double -> Int -> Int -> V.Vector ComplexDouble
prepareCoefficients !totalSamples !t0 !nMin !nMax = V.generate totalSamples $ \idx ->
    let currentN = nMin + idx
    in if currentN <= nMax
       then let n = fromIntegral currentN
                phi = -t0 * log n
                baseTerm = (1.0 / sqrt n) :+ 0.0
                phaseShift = exp (0.0 :+ phi)
            in baseTerm * phaseShift
       else 0.0 :+ 0.0

-- | 2. Оптимизированный блочный расчет через БПФ с выровненными векторами
evalBlockOD :: Double -> Double -> Int -> V.Vector Double
evalBlockOD !t0 !deltaT !samples = 
    let nMax = floor (sqrt ((t0 + deltaT) / (2 * pi)))
        nMin = 1
        coeffs = prepareCoefficients samples t0 nMin nMax
        fftResult = FFT.run FFT.dft coeffs
        theta !t = (t / 2) * log (t / (2 * pi)) - (t / 2) - (pi / 8)
    in V.imap (\idx complexVal ->
        let t = t0 + (fromIntegral idx * (deltaT / fromIntegral samples))
            realPartVal = realPart (complexVal * exp (0.0 :+ theta t))
        in 2 * realPartVal
       ) fftResult

-- | 3. Поиск нулей внутри вычисленного вектора значений Z-функции
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

-- | 4. Строгий параллельный конвейер без ленивых задержек планировщика
processPipeline :: Double -> Double -> Double -> IO [Double]
processPipeline !globalStart !globalEnd !blockSize = do
    let !blocks = [ (t, min globalEnd (t + blockSize)) 
                  | t <- [globalStart, globalStart + blockSize .. globalEnd - 1] ]
        samplesPerBlock = 524288 
    
    let !chunksOfZeros = withStrategy (parListChunk 16 rdeepseq) $ map (\(s, e) ->
                           findZerosInVector s (e - s) (evalBlockOD s (e - s) samplesPerBlock)
                         ) blocks
                         
    return $ concat chunksOfZeros

-- | 5. СТАБИЛЬНАЯ ФУНКЦИЯ ЗАПИСИ (Последовательный стриминг батчей через zipWithM_)
sendToInflux :: String -> [Double] -> IO ()
sendToInflux _ [] = return ()
sendToInflux blockNumStr zeros = do
    let host = "http://127.0.0.1:8086"
        path = "/api/v2/write"
        queryOrg = "?org=zeta_org"
        queryBucket = "&bucket=zeta_bucket"
        queryPrecision = "&precision=ns"
        url = host ++ path ++ queryOrg ++ queryBucket ++ queryPrecision

    let token = "ZetaStressSecretToken2026FFFFFFFFFFFF" 
        
        opts = W.defaults 
             & W.header "Authorization" .~ [BS.pack ("Token " ++ token)]
             & W.header "Content-Type" .~ [BS.pack "text/plain; charset=utf-8"]

    let sizeBatches = 200000
        chunks = chunksOf sizeBatches zeros
        totalChunks = length chunks

    putStrLn $ "Отправка в InfluxDB (" ++ show totalChunks ++ " батчей по " ++ show sizeBatches ++ " точек)..."

    let indices = [1 .. totalChunks] :: [Int]
    
    -- Последовательный обход: защищает локальный сервер InfluxDB от сетевого перегруза
    zipWithM_ (\idx chunk -> do
        let payloadLines = map (\z -> "riemann_zeta,block=" ++ blockNumStr ++ " value=" ++ show z) chunk
            payloadBody  = BL.pack (unlines payloadLines)
        
        _ <- W.postWith opts url payloadBody
        
        if idx `mod` 50 == 0 || idx == totalChunks
            then printf "  [Запись] Доставлено батчей: %d/%d\n" idx totalChunks
            else return ()
      ) indices chunks

    putStrLn "[+] Все батчи успешно доставлены в InfluxDB без перегрузки сервера."

main :: IO ()
main = do
    args <- getArgs
    case args of
        [blockNumStr, startStr, endStr] -> do
            let tStart    = read startStr :: Double
                tEnd      = read endStr :: Double
                blockSize = 10000.0 
            
            allZeros <- processPipeline tStart tEnd blockSize
            
            let (!totalCount, !last10) = foldl' (\(!cnt, !acc) z -> 
                    (cnt + 1, drop (if length acc >= 10 then 1 else 0) acc ++ [z])) (0, []) allZeros :: (Int, [Double])
            
            let filePath = "riemann_chunks_summary.csv"
            withFile filePath AppendMode $ \handle -> do
                hPutStrLn handle $ blockNumStr ++ ";" ++ startStr ++ ";" ++ endStr ++ ";" ++ show totalCount
                
            sendToInflux blockNumStr allZeros
                
            putStrLn "========================================"
            printf "Блок №%s успешно обработан.\n" blockNumStr
            printf "Интервал: от %.1f до %.1f\n" tStart tEnd
            printf "Найдено нулей в этом батче: %d\n" totalCount
            printf "Последние 10 найденных мнимых частей:\n"
            mapM_ (\z -> printf "  t = %.4f\n" z) last10
            putStrLn "========================================"
            
        _ -> putStrLn "Ошибка: Передайте аргументы: ./zeta_stress <номер_блока> <tStart> <tEnd>"
