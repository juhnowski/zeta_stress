{-# LANGUAGE BangPatterns #-}

import qualified Data.Vector.Storable as V
import qualified Data.Vector.Storable.Mutable as MV
import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar)
import Control.Monad (forM, forM_)
import System.IO
import System.Directory (doesFileExist)
import System.Exit (exitWith, ExitCode(..))
import System.Environment (getArgs)
import Text.Printf (printf)

blockDevicePath :: FilePath
blockDevicePath = "/dev/md0"

pointerFilePath :: FilePath
pointerFilePath = "riemann_block_pointer.txt"

maxDeviceLimitBytes :: Integer
maxDeviceLimitBytes = 8100 * 1024 * 1024 * 1024 -- 8.1 Тб

-- | 1. Математическое ядро (чистый цикл на регистрах, идеальный под AVX)
evalZ :: Double -> Double
evalZ !t =
    let !nMax = floor (sqrt (t / (2.0 * pi)))
        !theta = (t / 2.0) * log (t / (2.0 * pi)) - (t / 2.0) - (pi / 8.0)
        go !idx !acc
            | idx > nMax = acc
            | otherwise =
                let !n = fromIntegral idx
                    !term = cos (theta - t * log n) / sqrt n
                in go (idx + 1) (acc + term)
    in 2.0 * go 1 0.0

-- | 2. Расчет сетки Z-функции на подблоке
evalBlockZ :: Double -> Double -> Int -> V.Vector Double
evalBlockZ !t0 !deltaT !samples = V.generate samples $ \idx ->
    let !t = t0 + (fromIntegral idx * (deltaT / fromIntegral samples))
    in evalZ t

-- | 3. Поиск нулей (сразу пишет в Vector Double)
findZerosInVector :: Double -> Double -> V.Vector Double -> V.Vector Double
findZerosInVector !t0 !deltaT !vals = V.create $ do
    let !len = V.length vals
        !step = deltaT / fromIntegral len
    mv <- MV.new len
    let go !i !count
          | i >= len - 1 = return count
          | otherwise = do
              let !v1 = vals V.! i
                  !v2 = vals V.! (i + 1)
                  !isZero = (v1 > 0 && v2 < 0) || (v1 < 0 && v2 > 0)
                  !tZero = t0 + (fromIntegral i * step) + (step / 2.0)
              if isZero
                  then do MV.write mv count tZero; go (i + 1) (count + 1)
                  else go (i + 1) count
    actualCount <- go 0 0
    return $ MV.take actualCount mv

-- | 4. НИЗКОУРОВНЕВЫЙ ДИСПЕТЧЕР: нарезает диапазон строго на 124 куска под OS-потоки
processPipelineConcurrent :: Double -> Double -> IO (V.Vector Double)
processPipelineConcurrent !globalStart !globalEnd = do
    let numCores = 124
        !totalDelta = globalEnd - globalStart
        !chunkSize = totalDelta / fromIntegral numCores
        !samplesPerCore = 4000 * (1000 `div` numCores) -- сохраняем плотность шага ~4000000 на макробатч
        
    -- Создаем MVar для каждого из 124 потоков
    mvars <- forM [0 .. numCores - 1] $ \_ -> newEmptyMVar
    
    -- Асинхронно запускаем вычисления в изолированных системных потоках
    forM_ (zip [0 .. numCores - 1] mvars) $ \(coreIdx, mvar) -> forkIO $ do
        let !s = globalStart + fromIntegral coreIdx * chunkSize
            !e = s + chunkSize
            -- Каждый поток считает свой гигантский кусок и заполняет вектор
            !zeros = findZerosInVector s (e - s) (evalBlockZ s (e - s) samplesPerCore)
        putMVar mvar zeros
        
    -- Собираем результаты из всех 124 MVar (блокирующий сбор)
    chunks <- mapM takeMVar mvars
    return $ V.concat chunks

getCurrentOffset :: IO Integer
getCurrentOffset = do
    exists <- doesFileExist pointerFilePath
    if exists
        then do
            content <- readFile pointerFilePath
            let !offset = read (head (lines content)) :: Integer
            return offset
        else return 0

main :: IO ()
main = do
    args <- getArgs
    case args of
        [blockNumStr, startStr, endStr] -> do
            let tStart = read startStr :: Double
                tEnd   = read endStr :: Double
            
            -- Запуск прямого многопоточного расчета без рантайм-посредников
            storableVector <- processPipelineConcurrent tStart tEnd
            
            let !totalCount  = V.length storableVector
                !sizeInBytes = fromIntegral (totalCount * 8) :: Integer
                !last10      = V.toList $ V.drop (max 0 (totalCount - 10)) storableVector

            currentOffset <- getCurrentOffset
            
            if currentOffset + sizeInBytes > maxDeviceLimitBytes
                then do
                    putStrLn "\n[!!!] КРИТИЧЕСКИЙ ОСТАНОВ: Достигнут лимит выделенных 8.1 Тб на RAID-0."
                    exitWith (ExitFailure 2)
                else return ()

            withFile blockDevicePath ReadWriteMode $ \devHandle -> do
                hSetBuffering devHandle NoBuffering
                hSeek devHandle AbsoluteSeek currentOffset
                V.unsafeWith storableVector $ \ptr ->
                    hPutBuf devHandle ptr (fromIntegral sizeInBytes)
                hFlush devHandle

            let !newOffset = currentOffset + sizeInBytes
            writeFile pointerFilePath (show newOffset ++ "\n")

            let csvPath = "riemann_chunks_summary.csv"
            withFile csvPath AppendMode $ \handle -> do
                hPutStrLn handle $ printf "%s;%s;%s;%d;%d" blockNumStr startStr endStr totalCount newOffset
                
            let remainingBytes = maxDeviceLimitBytes - newOffset
            putStrLn "========================================"
            printf "Блок №%s успешно записан НАПРЯМУЮ НА RAID-0.\n" blockNumStr
            printf "Интервал: от %.1f до %.1f\n" tStart tEnd
            printf "Текущее смещение на устройстве: %d байт (~%.2f Гб)\n" newOffset (fromIntegral newOffset / (1024**3) :: Double)
            printf "Осталось свободного места: %.2f Гб из 8.1 Тб\n" (fromIntegral remainingBytes / (1024**3) :: Double)
            printf "Найдено нулей в батче: %d\n" totalCount
            printf "Последние 10 найденных мнимых частей:\n"
            mapM_ (\z -> printf "  t = %.4f\n" z) last10
            putStrLn "========================================"
            
        _ -> putStrLn "Ошибка: Передайте аргументы: ./zeta_stress <номер_блока> <tStart> <tEnd>"
