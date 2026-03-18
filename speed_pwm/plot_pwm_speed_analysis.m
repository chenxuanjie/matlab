%% PWM-速度实验日志分析脚本
% 功能说明：
% 1. 支持读取单个日志文件，或一个文件夹中的多个日志文件。
% 2. 从日志中解析 timestamp、pwm、speed_mps 三个字段。
% 3. 绘制全程 time-pwm 点线图。
% 4. 绘制全程 time-speed 点线图。
% 5. 绘制分阶段 time-speed 子图。
% 6. 提取每个 PWM 阶段后段的平均速度，作为稳态速度。
% 7. 绘制稳态 pwm-speed 散点图，并在同一张图中完成最小二乘拟合。
%
% 日志格式示例：
% speed_pwm_experiment timestamp=0.000, speed_mps=0.000000, vx=0.000000, vy=0.000000, vz=0.000000, pwm=1000, control_mode=1, speed_stamp=0.000, speed_age=0.000
% speed_pwm_experiment timestamp=1.000, speed_mps=0.120000, vx=0.120000, vy=0.000000, vz=0.000000, pwm=1000, control_mode=1, speed_stamp=1.000, speed_age=0.010
%
% 使用建议：
% - 如果你的实验被拆成多个文件，推荐使用“文件夹批量读取”模式。
% - 如果多个文件里的 timestamp 是真实时间戳（只是不会从 0 开始），建议把 timeMergeMode 设为 'sort'。
% - 读取完成后，脚本会先把 timestamp 转成秒，再用所有有效点中的最小时间戳作为 0 秒起点。

clc;
clear;
close all;

scriptDir = fileparts(mfilename('fullpath'));

%% ======================== 输入配置区（可直接修改） ========================

% 输入模式：
% 'single' -> 读取单个日志文件
% 'folder' -> 读取某个文件夹中的所有匹配日志文件
inputMode = 'folder';

% 当 inputMode = 'single' 时，logPath 填文件路径；
% 当 inputMode = 'folder' 时，logPath 填文件夹路径， 例如：'experiment_tests'
logPath = 'experiment_tests';

% 仅在 inputMode = 'folder' 时生效：文件匹配模式
% 例如：'*.log'、'speed_pwm_*.log'；文件夹模式下会递归遍历所有子文件夹
filePattern = '*.log';

% 仅在 inputMode = 'folder' 时生效：文件排序方式
% 'name'   -> 按文件名排序
% 'date'   -> 按修改时间排序
% 'number' -> 从文件名中提取第一个数字并排序（如果文件名里带 PWM，推荐这个）
folderSortMode = 'number';

% 仅在 inputMode = 'folder' 时生效：多文件时间合并方式
% 'append_offset' -> 按文件顺序拼接；每个文件都从自身起点重新计时，再接到前一个文件后面
% 'sort'          -> 直接按 timestamp 数值合并，适合全局时间戳日志
% 推荐：如果 timestamp 是真实时间戳，选 'sort'
timeMergeMode = 'sort';

% 仅在 inputMode = 'folder' 且 timeMergeMode = 'append_offset' 时生效：
% 在相邻两个文件之间额外插入多少时间间隔（单位：秒）
timeGapBetweenFiles = 0;

% 是否跳过没有解析到有效数据的文件
skipEmptyFiles = true;

% 时间戳原始单位：
% 's'  -> 秒
% 'ms' -> 毫秒
% 'us' -> 微秒
% 'ns' -> 纳秒
timestampUnit = 's';

% 是否将所有有效点中的最小时间戳作为 0 秒起点
normalizeTimeToZero = true;

%% ======================== 字段配置区 ========================

% 日志中三个字段对应的名称
% 如果你的日志写成 timestamp=..., duty=..., velocity=...
% 那就把下面三个变量改成对应字段名即可。
timeKey  = 'timestamp';
pwmKey   = 'pwm';
speedKey = 'speed_mps';

%% ======================== 分析参数区 ========================

% 稳态提取参数：取每个 PWM 阶段最后多少比例的数据做平均
steadyStateFraction = 0.30;

% 每个阶段最少用于稳态平均的点数
minSteadyPoints = 3;

% 最小二乘拟合阶数
% 1 = 直线拟合
% 2 = 二次拟合
fitDegree = 2;

% 拟合模型符号说明：
% u = k1 * n^2 + k2 * n + k3
% 其中：
% u -> 稳态速度
% n -> PWM
fitResponseSymbol = 'u';
fitVariableSymbol = 'n';

% 是否在拟合中额外加入一个人工约束点
% 例如可加入“PWM = 1500 时，速度 = 0”这一先验信息
enableExtraFitPoint = true;
extraFitPointPwm = 1500;
extraFitPointSpeed = 0;

% 是否在稳态散点图中显示这个额外拟合点
showExtraFitPointOnPlot = true;

% 分阶段 time-speed 子图中是否使用相对时间
% true  -> 每一段都从 0 开始计时，更便于比较各段响应过程
% false -> 使用拼接后的绝对时间
useRelativeTimeInSegmentPlots = true;

% 分阶段 time-speed 子图的统一显示时长（单位：秒）
% 设为 25，表示每个 PWM 子图横坐标统一显示 0~25 s
segmentPlotDuration = 25;

% 是否统一分阶段 time-speed 子图的纵坐标范围
unifySegmentPlotYLimits = true;

% 统一纵坐标时的上下留白比例
segmentYLimitPaddingRatio = 0.08;

% 分阶段子图是否使用更紧凑的论文排版布局
compactSegmentFigureLayout = true;

% 更紧凑布局时，是否只保留外侧坐标标签
% true  -> 左列保留 ylabel，底行保留 xlabel
% false -> 每个子图都显示完整坐标标签
showOuterLabelsOnly = true;

% 绘图样式
lineWidth = 1.1;
markerSize = 5;
pointMarkerSize = 9;
steadyScatterSize = 24;
fitLineWidth = 1.4;
actualDataColor = [74, 35, 120] / 255;
actualLineColor = [170, 160, 196] / 255;
fitLineColor = [0.82, 0.10, 0.10];

%% ======================== 读取与解析日志 ========================

resolvedLogPath = resolveInputPath(logPath, scriptDir);

[timeData, pwmData, speedData, sourceSegmentId, rawLineCount, sourceInfo] = loadLogSource( ...
    inputMode, resolvedLogPath, filePattern, folderSortMode, timeMergeMode, timeGapBetweenFiles, ...
    timeKey, pwmKey, speedKey, skipEmptyFiles, timestampUnit);

if isempty(timeData)
    error('没有从日志中解析到有效数据，请检查路径、格式和字段名设置。');
end

if numel(timeData) ~= numel(pwmData) || numel(timeData) ~= numel(speedData) || ...
        numel(timeData) ~= numel(sourceSegmentId)
    error('Parsed time, pwm, speed, and sourceSegmentId lengths are inconsistent.');
end

if strcmpi(inputMode, 'single') || strcmpi(timeMergeMode, 'sort')
    [timeData, sortIdx] = sort(timeData(:));
    pwmData = pwmData(sortIdx);
    speedData = speedData(sortIdx);
    sourceSegmentId = sourceSegmentId(sortIdx);
else
    timeData = timeData(:);
    pwmData = pwmData(:);
    speedData = speedData(:);
    sourceSegmentId = sourceSegmentId(:);
end

if normalizeTimeToZero
    minValidTime = min(timeData);
    timeData = timeData - minValidTime;
else
    minValidTime = NaN;
end

fprintf('读取模式：%s\n', sourceInfo.inputMode);
fprintf('输入路径：%s\n', sourceInfo.logPath);
fprintf('匹配文件数：%d\n', sourceInfo.fileCount);
fprintf('总有效记录数：%d\n', numel(timeData));
fprintf('原始日志总行数：%d\n', rawLineCount);
fprintf('时间戳原始单位：%s\n', timestampUnit);
fprintf('时间已统一转换为：秒 (s)\n');
if normalizeTimeToZero
    fprintf('已使用最小有效时间戳作为 0 秒起点：%.9f s\n', minValidTime);
end
if strcmpi(sourceInfo.inputMode, 'folder')
    fprintf('文件排序方式：%s\n', sourceInfo.folderSortMode);
    fprintf('时间合并方式：%s\n', sourceInfo.timeMergeMode);
end

%% ======================== 按 PWM 变化分阶段 ========================

segments = splitIntoPwmSegments(timeData, pwmData, speedData, sourceSegmentId);
numSegments = numel(segments);

fprintf('识别到 PWM 阶段数：%d\n', numSegments);

%% ======================== 图 1：全程 time-pwm ========================

figure('Name', 'Full Time-PWM', 'Color', 'w');
hold on;
plot(timeData, pwmData, '-', 'Color', actualLineColor, 'LineWidth', lineWidth, ...
    'HandleVisibility', 'off');
plot(timeData, pwmData, '.', 'Color', actualDataColor, 'MarkerSize', pointMarkerSize, ...
    'DisplayName', 'PWM 采样点');
applyThesisAxesStyle();
xlabel('Time (s)');
ylabel('PWM');
title('全程 PWM 随时间变化点线图');
legend('Location', 'best');
hold off;

%% ======================== 图 2：全程 time-speed ========================

figure('Name', 'Full Time-Speed', 'Color', 'w');
hold on;
plot(timeData, speedData, '-', 'Color', actualLineColor, 'LineWidth', lineWidth, ...
    'HandleVisibility', 'off');
plot(timeData, speedData, '.', 'Color', actualDataColor, 'MarkerSize', pointMarkerSize, ...
    'DisplayName', '速度采样点');
applyThesisAxesStyle();
xlabel('Time (s)');
ylabel('Speed (m/s)');
title('全程速度随时间变化点线图');
legend('Location', 'best');
hold off;

%% ======================== 图 3：按唯一 PWM 汇总的 time-speed 子图 ========================

uniquePwmValues = sort(unique([segments.pwmValue]));
numUniquePwms = numel(uniquePwmValues);

segmentYLimits = [];
if unifySegmentPlotYLimits
    segmentSpeedMin = min(speedData);
    segmentSpeedMax = max(speedData);
    segmentSpeedRange = segmentSpeedMax - segmentSpeedMin;

    if segmentSpeedRange < eps
        yPadding = max(0.05, 0.1 * max(1, abs(segmentSpeedMax)));
    else
        yPadding = segmentYLimitPaddingRatio * segmentSpeedRange;
    end

    segmentYLimits = [segmentSpeedMin - yPadding, segmentSpeedMax + yPadding];
end

figure('Name', 'Segmented Time-Speed', 'Color', 'w');
[numRows, numCols] = calcSubplotLayout(numUniquePwms);

segmentTileLayout = [];
if exist('tiledlayout', 'file') == 2 || exist('tiledlayout', 'builtin') == 5
    if compactSegmentFigureLayout
        segmentTileLayout = tiledlayout(numRows, numCols, 'TileSpacing', 'none', 'Padding', 'compact');
    else
        segmentTileLayout = tiledlayout(numRows, numCols, 'TileSpacing', 'compact', 'Padding', 'compact');
    end
end

for i = 1:numUniquePwms
    currentPwm = uniquePwmValues(i);
    currentSegments = segments([segments.pwmValue] == currentPwm);
    currentRow = ceil(i / numCols);
    currentCol = mod(i - 1, numCols) + 1;

    if isempty(segmentTileLayout)
        subplot(numRows, numCols, i);
    else
        nexttile(segmentTileLayout, i);
    end
    hold on;

    for runIndex = 1:numel(currentSegments)
        currentTime = currentSegments(runIndex).time;
        currentSpeed = currentSegments(runIndex).speed;

        if useRelativeTimeInSegmentPlots
            plotTime = currentTime - currentTime(1);
            xLabelText = 'Relative Time (s)';
        else
            plotTime = currentTime;
            xLabelText = 'Time (s)';
        end

        plot(plotTime, currentSpeed, '.', 'Color', actualDataColor, 'MarkerSize', pointMarkerSize, ...
            'HandleVisibility', 'off');
    end

    applyThesisAxesStyle();
    ax = gca;
    ax.PositionConstraint = 'innerposition';

    if compactSegmentFigureLayout && showOuterLabelsOnly
        if currentRow == numRows
            xlabel(xLabelText);
        else
            xlabel('');
            ax.XTickLabel = [];
        end

        if currentCol == 1
            ylabel('Speed (m/s)');
        else
            ylabel('');
            ax.YTickLabel = [];
        end
    else
        xlabel(xLabelText);
        ylabel('Speed (m/s)');
    end

    if useRelativeTimeInSegmentPlots
        xlim([0, segmentPlotDuration]);
    else
        currentStartTime = min(arrayfun(@(segmentItem) segmentItem.time(1), currentSegments));
        xlim([currentStartTime, currentStartTime + segmentPlotDuration]);
    end

    if unifySegmentPlotYLimits
        ylim(segmentYLimits);
    end

    if numel(currentSegments) > 1
        title(sprintf('PWM = %.0f (%d runs)', currentPwm, numel(currentSegments)));
    else
        title(sprintf('PWM = %.0f', currentPwm));
    end

    hold off;
end

if ~isempty(segmentTileLayout)
    title(segmentTileLayout, '各 PWM 的速度-时间子图');
elseif exist('sgtitle', 'file') == 2 || exist('sgtitle', 'builtin') == 5
    sgtitle('各 PWM 的速度-时间子图');
else
    annotation('textbox', [0 0.96 1 0.03], ...
        'String', '各 PWM 的速度-时间子图', ...
        'EdgeColor', 'none', ...
        'HorizontalAlignment', 'center', ...
        'FontWeight', 'bold');
end

[steadyPwm, steadySpeed, steadyInfo] = computeSteadyStateByTailMean( ...
    segments, steadyStateFraction, minSteadyPoints);

fprintf('\n稳态提取结果：\n');
for i = 1:numel(steadyPwm)
    fprintf('阶段 %2d: PWM = %6.1f, 稳态速度均值 = %8.3f m/s, 使用点数 = %d\n', ...
        i, steadyPwm(i), steadySpeed(i), steadyInfo(i).numPointsUsed);
end

%% ======================== 图 4：稳态 pwm-speed + 加权最小二乘拟合 ========================

[fitWeights, fitWeightPwmValues, fitRepeatCounts] = buildBalancedPwmWeights(steadyPwm);
fitPwmData = steadyPwm;
fitSpeedData = steadySpeed;

if enableExtraFitPoint
    fitPwmData(end + 1, 1) = extraFitPointPwm;
    fitSpeedData(end + 1, 1) = extraFitPointSpeed;
end

[fitWeights, fitWeightPwmValues, fitRepeatCounts] = buildBalancedPwmWeights(fitPwmData);
numUniqueFitPwms = numel(fitWeightPwmValues);

figure('Name', 'Steady PWM-Speed with Fit', 'Color', 'w');
hold on;
applyThesisAxesStyle();

scatter(steadyPwm, steadySpeed, steadyScatterSize, 'o', ...
    'MarkerFaceColor', actualDataColor, ...
    'MarkerEdgeColor', actualDataColor, ...
    'LineWidth', 0.6, ...
    'DisplayName', '稳态散点');

if enableExtraFitPoint && showExtraFitPointOnPlot
    scatter(extraFitPointPwm, extraFitPointSpeed, steadyScatterSize + 10, 's', ...
        'MarkerFaceColor', fitLineColor, ...
        'MarkerEdgeColor', fitLineColor, ...
        'LineWidth', 0.8, ...
        'DisplayName', '附加拟合点');
end

if numUniqueFitPwms >= fitDegree + 1
    fitCoeff = weightedPolyfit(fitPwmData, fitSpeedData, fitDegree, fitWeights);
    xFit = linspace(min(fitPwmData), max(fitPwmData), 300);
    yFit = polyval(fitCoeff, xFit);

    plot(xFit, yFit, '-', 'Color', fitLineColor, 'LineWidth', fitLineWidth, ...
        'DisplayName', '加权最小二乘拟合');
    yPred = polyval(fitCoeff, fitPwmData);
    rSquared = computeWeightedRSquared(fitSpeedData, yPred, fitWeights);
    fitText = polynomialToString(fitCoeff, fitVariableSymbol);

    title({ ...
        '稳态 PWM-Speed 特性曲线' ...
        });
else
    warning('唯一 PWM 数量不足，无法进行 %d 阶加权拟合。', fitDegree);
    title('稳态 PWM-Speed 特性曲线（唯一 PWM 点不足，未进行拟合）');
end

xlabel('PWM');
ylabel('Steady Speed (m/s)');
legend('Location', 'best');
hold off;

%% ======================== 命令行输出拟合结果 ========================

if exist('fitCoeff', 'var')
    fprintf('\n加权最小二乘拟合结果：\n');
    fprintf('模型形式：%s = k1*%s^2 + k2*%s + k3\n', fitResponseSymbol, fitVariableSymbol, fitVariableSymbol);
    fprintf('变量含义：%s = SteadySpeed，%s = PWM\n', fitResponseSymbol, fitVariableSymbol);
    fprintf('辨识结果：%s = %s\n', fitResponseSymbol, polynomialToString(fitCoeff, fitVariableSymbol));
    printPolynomialCoefficientDetails(fitCoeff, 'PWM', 'SteadySpeed', fitVariableSymbol);
    fprintf('Weighted R^2 = %.6f\n', rSquared);

    if enableExtraFitPoint
        fprintf('附加拟合点：PWM = %.1f, SteadySpeed = %.3f m/s\n', extraFitPointPwm, extraFitPointSpeed);
    end

    fprintf('\n各 PWM 的重复试验点数与单点权重：\n');
    for weightIndex = 1:numel(fitWeightPwmValues)
        fprintf('PWM = %6.1f, 稳态点数 = %d, 单点权重 = %.4f, 该 PWM 总权重 = 1.0000\n', ...
            fitWeightPwmValues(weightIndex), fitRepeatCounts(weightIndex), 1 / fitRepeatCounts(weightIndex));
    end
end

fprintf('\n分析完成。\n');

%% ======================== 本地函数区 ========================

function resolvedPath = resolveInputPath(inputPath, scriptDir)
% 优先按脚本所在目录解析相对路径，避免切换工作目录后找不到日志。

    if isfolder(inputPath) || isfile(inputPath)
        resolvedPath = inputPath;
        return;
    end

    candidatePath = fullfile(scriptDir, inputPath);
    if isfolder(candidatePath) || isfile(candidatePath)
        resolvedPath = candidatePath;
    else
        resolvedPath = inputPath;
    end
end

function [timeData, pwmData, speedData, sourceSegmentId, rawLineCount, sourceInfo] = loadLogSource( ...
    inputMode, logPath, filePattern, folderSortMode, timeMergeMode, timeGapBetweenFiles, ...
    timeKey, pwmKey, speedKey, skipEmptyFiles, timestampUnit)
% 支持读取单文件，或批量读取一个文件夹中的多个日志文件。

    inputMode = lower(strtrim(char(string(inputMode))));

    switch inputMode
        case 'single'
            if ~isfile(logPath)
                error('找不到日志文件：%s', logPath);
            end

            [timeData, pwmData, speedData, rawLines] = parseLogFile(logPath, timeKey, pwmKey, speedKey);
            timeData = convertTimestampToSeconds(timeData, timestampUnit);
            sourceSegmentId = ones(size(timeData));
            rawLineCount = numel(rawLines);

            sourceInfo = struct();
            sourceInfo.inputMode = 'single';
            sourceInfo.logPath = logPath;
            sourceInfo.fileCount = 1;
            sourceInfo.folderSortMode = 'none';
            sourceInfo.timeMergeMode = 'none';

        case 'folder'
            if ~isfolder(logPath)
                error('找不到日志文件夹：%s', logPath);
            end

            fileList = collectLogFiles(logPath, filePattern, folderSortMode);
            if isempty(fileList)
                error('在文件夹及其子文件夹中没有找到匹配的日志文件：%s', fullfile(logPath, '**', filePattern));
            end

            timeData = [];
            pwmData = [];
            speedData = [];
            sourceSegmentId = [];
            rawLineCount = 0;
            currentTimeOffset = 0;
            validFileCount = 0;

            for i = 1:numel(fileList)
                currentFile = fullfile(fileList(i).folder, fileList(i).name);
                [currentTime, currentPwm, currentSpeed, rawLines] = parseLogFile(currentFile, timeKey, pwmKey, speedKey);
                currentTime = convertTimestampToSeconds(currentTime, timestampUnit);
                rawLineCount = rawLineCount + numel(rawLines);

                if isempty(currentTime)
                    if skipEmptyFiles
                        fprintf('跳过空文件或无有效数据文件：%s\n', currentFile);
                        continue;
                    else
                        error('文件未解析到有效数据：%s', currentFile);
                    end
                end

                validFileCount = validFileCount + 1;

                if strcmpi(timeMergeMode, 'append_offset')
                    currentTime = currentTime - currentTime(1);
                    if isempty(timeData)
                        currentTime = currentTime + currentTimeOffset;
                    else
                        currentTime = currentTime + currentTimeOffset + timeGapBetweenFiles;
                    end
                    currentTimeOffset = currentTime(end);
                elseif strcmpi(timeMergeMode, 'sort')
                    currentTime = currentTime(:);
                else
                    error('timeMergeMode 仅支持 append_offset 或 sort。');
                end

                currentSourceSegmentId = validFileCount * ones(numel(currentTime), 1);

                timeData = [timeData; currentTime(:)]; %#ok<AGROW>
                pwmData = [pwmData; currentPwm(:)]; %#ok<AGROW>
                speedData = [speedData; currentSpeed(:)]; %#ok<AGROW>
                sourceSegmentId = [sourceSegmentId; currentSourceSegmentId(:)]; %#ok<AGROW>
            end

            sourceInfo = struct();
            sourceInfo.inputMode = 'folder';
            sourceInfo.logPath = logPath;
            sourceInfo.fileCount = validFileCount;
            sourceInfo.folderSortMode = folderSortMode;
            sourceInfo.timeMergeMode = timeMergeMode;

        otherwise
            error('inputMode 仅支持 single 或 folder。');
    end
end

function timeSeconds = convertTimestampToSeconds(timeData, timestampUnit)
% 将原始 timestamp 按指定单位转换成秒。

    timestampUnit = lower(strtrim(char(string(timestampUnit))));

    switch timestampUnit
        case {'s', 'sec', 'second', 'seconds'}
            scale = 1;
        case {'ms', 'millisecond', 'milliseconds'}
            scale = 1e-3;
        case {'us', 'microsecond', 'microseconds'}
            scale = 1e-6;
        case {'ns', 'nanosecond', 'nanoseconds'}
            scale = 1e-9;
        otherwise
            error('timestampUnit 仅支持 s / ms / us / ns。');
    end

    timeSeconds = timeData(:) * scale;
end

function fileList = collectLogFiles(folderPath, filePattern, folderSortMode)
% 递归收集文件夹及其所有子文件夹中匹配的日志文件，并按指定规则排序。
% 当文件名包含类似 _1、_2、_3 的重复试验后缀时，number 模式会先按 PWM 排序，
% 再按后缀编号排序，避免 speed_pwm_experiment_1600_10 排在 _1600_2 前面。

    fileList = collectLogFilesRecursive(folderPath, filePattern);

    if isempty(fileList)
        return;
    end

    folderSortMode = lower(strtrim(char(string(folderSortMode))));
    fullPaths = lower(strcat({fileList.folder}', repmat({filesep}, numel(fileList), 1), {fileList.name}'));

    switch folderSortMode
        case 'name'
            [~, sortIdx] = sort(fullPaths);

        case 'date'
            [~, sortIdx] = sort([fileList.datenum]);

        case 'number'
            primaryKeys = inf(numel(fileList), 1);
            repeatKeys = zeros(numel(fileList), 1);
            for i = 1:numel(fileList)
                [primaryKeys(i), repeatKeys(i)] = extractFileNumberKeys(fileList(i).name);
            end

            helperTable = table(primaryKeys, repeatKeys, fullPaths(:), (1:numel(fileList))', ...
                'VariableNames', {'PrimaryKey', 'RepeatKey', 'FilePath', 'OriginalIndex'});
            helperTable = sortrows(helperTable, {'PrimaryKey', 'RepeatKey', 'FilePath', 'OriginalIndex'});
            sortIdx = helperTable.OriginalIndex;

        otherwise
            error('folderSortMode only supports name / date / number.');
    end

    fileList = fileList(sortIdx);
end

function fileList = collectLogFilesRecursive(folderPath, filePattern)
% 递归扫描当前文件夹及全部子文件夹，返回所有匹配的日志文件。

    currentFiles = dir(fullfile(folderPath, filePattern));
    currentFiles = currentFiles(~[currentFiles.isdir]);
    fileList = currentFiles;

    subEntries = dir(folderPath);
    subEntries = subEntries([subEntries.isdir]);
    subFolderNames = {subEntries.name};
    validMask = ~ismember(subFolderNames, {'.', '..'});
    subEntries = subEntries(validMask);

    for i = 1:numel(subEntries)
        subFolderPath = fullfile(folderPath, subEntries(i).name);
        nestedFiles = collectLogFilesRecursive(subFolderPath, filePattern);
        if ~isempty(nestedFiles)
            fileList = [fileList; nestedFiles]; %#ok<AGROW>
        end
    end
end
function [primaryKey, repeatKey] = extractFileNumberKeys(fileName)
% Extract numeric sort keys from file names.
% Example: speed_pwm_experiment_1600_2.log -> primaryKey = 1600, repeatKey = 2

    tokens = regexp(fileName, '([+-]?\d+(?:\.\d+)?)', 'match');

    if isempty(tokens)
        primaryKey = inf;
        repeatKey = 0;
        return;
    end

    primaryKey = str2double(tokens{1});
    if numel(tokens) >= 2
        repeatKey = str2double(tokens{2});
    else
        repeatKey = 0;
    end
end

function [timeData, pwmData, speedData, rawLines] = parseLogFile(logFile, timeKey, pwmKey, speedKey)
% 读取日志文件，并从每一行中提取 time / pwm / speed 三个数值字段。

    fileText = fileread(logFile);
    rawLines = splitlines(string(fileText));

    timeData = [];
    pwmData = [];
    speedData = [];

    for lineIndex = 1:numel(rawLines)
        oneLine = strtrim(rawLines(lineIndex));

        if strlength(oneLine) == 0
            continue;
        end

        timeValue = extractNumericValue(oneLine, timeKey);
        pwmValue = extractNumericValue(oneLine, pwmKey);
        speedValue = extractNumericValue(oneLine, speedKey);

        if ~(isnan(timeValue) || isnan(pwmValue) || isnan(speedValue))
            timeData(end + 1, 1) = timeValue; %#ok<AGROW>
            pwmData(end + 1, 1) = pwmValue; %#ok<AGROW>
            speedData(end + 1, 1) = speedValue; %#ok<AGROW>
        end
    end
end

function value = extractNumericValue(oneLine, keyName)
% 从一行日志里提取 key=value 中的数值。
% 兼容如下格式：
%   speed_pwm_experiment timestamp=0.000, speed_mps=0.123, ..., pwm=1200, ...
% 支持前缀文本、额外字段、整数、小数和科学计数法。

    pattern = ['(?:^|[^A-Za-z0-9_])\s*', regexptranslate('escape', keyName), ...
        '\s*=\s*([+-]?\d*\.?\d+(?:[eE][+-]?\d+)?)'];

    token = regexp(char(oneLine), pattern, 'tokens', 'once');

    if isempty(token)
        value = NaN;
    else
        value = str2double(token{1});
    end
end

function segments = splitIntoPwmSegments(timeData, pwmData, speedData, sourceSegmentId)
% Split the full dataset when PWM changes or when the source file changes.
% This keeps files like speed_pwm_experiment_1600_1.log and
% speed_pwm_experiment_1600_2.log as two independent experiment stages.

    if isempty(pwmData)
        segments = struct('time', {}, 'pwm', {}, 'speed', {}, 'pwmValue', {}, 'sourceSegmentId', {});
        return;
    end

    changeMask = diff(pwmData) ~= 0 | diff(sourceSegmentId) ~= 0;
    changeIndex = [1; find(changeMask) + 1; numel(pwmData) + 1];
    segmentCount = numel(changeIndex) - 1;

    segments = repmat(struct('time', [], 'pwm', [], 'speed', [], 'pwmValue', [], 'sourceSegmentId', []), segmentCount, 1);

    for i = 1:segmentCount
        startIdx = changeIndex(i);
        endIdx = changeIndex(i + 1) - 1;

        segments(i).time = timeData(startIdx:endIdx);
        segments(i).pwm = pwmData(startIdx:endIdx);
        segments(i).speed = speedData(startIdx:endIdx);
        segments(i).pwmValue = pwmData(startIdx);
        segments(i).sourceSegmentId = sourceSegmentId(startIdx);
    end
end

function [steadyPwm, steadySpeed, steadyInfo] = computeSteadyStateByTailMean(segments, fraction, minPoints)
% 对每个 PWM 阶段取尾部一部分数据做平均，得到稳态速度。

    segmentCount = numel(segments);

    steadyPwm = zeros(segmentCount, 1);
    steadySpeed = zeros(segmentCount, 1);
    steadyInfo = repmat(struct('startIndexUsed', [], 'endIndexUsed', [], 'numPointsUsed', []), segmentCount, 1);

    for i = 1:segmentCount
        currentSpeed = segments(i).speed;
        totalPoints = numel(currentSpeed);

        pointsFromFraction = ceil(totalPoints * fraction);
        pointsToUse = max(pointsFromFraction, minPoints);
        pointsToUse = min(pointsToUse, totalPoints);

        startIdx = totalPoints - pointsToUse + 1;
        endIdx = totalPoints;
        steadyRange = currentSpeed(startIdx:endIdx);

        steadyPwm(i) = segments(i).pwmValue;
        steadySpeed(i) = mean(steadyRange);

        steadyInfo(i).startIndexUsed = startIdx;
        steadyInfo(i).endIndexUsed = endIdx;
        steadyInfo(i).numPointsUsed = pointsToUse;
    end
end

function [numRows, numCols] = calcSubplotLayout(numPlots)
% 根据子图数量自动计算较均衡的布局。

    numRows = ceil(sqrt(numPlots));
    numCols = ceil(numPlots / numRows);
end

function applyThesisAxesStyle()
% 统一设置毕业论文中更常见的坐标轴风格。
% 说明：白底、带边框、适中的线宽和字号，适合后续插入论文。

    grid on;
    box on;
    ax = gca;
    ax.LineWidth = 0.9;
    ax.FontSize = 11;
end

function rSquared = computeRSquared(yTrue, yPred)
% Compute standard R^2.

    ssRes = sum((yTrue - yPred).^2);
    ssTot = sum((yTrue - mean(yTrue)).^2);

    if ssTot == 0
        rSquared = 1;
    else
        rSquared = 1 - ssRes / ssTot;
    end
end

function [weights, uniquePwmValues, repeatCounts] = buildBalancedPwmWeights(steadyPwm)
% Build balanced fitting weights for steady-state scatter points.
% Rule: the sum of weights for each PWM is the same,
% so PWM values with more repeated trials do not dominate the fit.

    [uniquePwmValues, ~, groupIndex] = unique(steadyPwm(:), 'stable');
    repeatCounts = accumarray(groupIndex, 1);
    weights = 1 ./ repeatCounts(groupIndex);
end

function coeff = weightedPolyfit(xData, yData, degree, weights)
% Perform weighted polynomial least-squares fitting.
% When degree = 1, this becomes a weighted straight-line fit.

    xData = xData(:);
    yData = yData(:);
    weights = weights(:);

    if numel(xData) ~= numel(yData) || numel(xData) ~= numel(weights)
        error('weightedPolyfit input lengths are inconsistent.');
    end

    vandermondeMatrix = zeros(numel(xData), degree + 1);
    for powerIndex = 0:degree
        vandermondeMatrix(:, degree - powerIndex + 1) = xData .^ powerIndex;
    end

    sqrtWeights = sqrt(weights);
    weightedMatrix = vandermondeMatrix .* sqrtWeights;
    weightedTarget = yData .* sqrtWeights;
    coeff = weightedMatrix \ weightedTarget;
    coeff = coeff.';
end

function rSquared = computeWeightedRSquared(yTrue, yPred, weights)
% Compute weighted R^2.

    yTrue = yTrue(:);
    yPred = yPred(:);
    weights = weights(:);

    weightedMean = sum(weights .* yTrue) / sum(weights);
    ssRes = sum(weights .* (yTrue - yPred).^2);
    ssTot = sum(weights .* (yTrue - weightedMean).^2);

    if ssTot == 0
        rSquared = 1;
    else
        rSquared = 1 - ssRes / ssTot;
    end
end


function printPolynomialCoefficientDetails(coeff, variableName, responseName, variableSymbol)
% 打印多项式系数的详细说明。
% 当前约定：k1 对应二次项，k2 对应一次项，k3 对应常数项。

    degree = numel(coeff) - 1;
    fprintf('系数说明（按 polyfit 输出顺序）：\n');

    for idx = 1:numel(coeff)
        powerValue = degree - (idx - 1);
        coeffLabel = sprintf('k%d', idx);

        if powerValue > 1
            fprintf('  %s = %.10g    -> %s^%d 项系数（即 %s * %s^%d）\n', ...
                coeffLabel, coeff(idx), variableSymbol, powerValue, coeffLabel, variableSymbol, powerValue);
        elseif powerValue == 1
            fprintf('  %s = %.10g    -> %s 一次项系数（即 %s * %s）\n', ...
                coeffLabel, coeff(idx), variableSymbol, coeffLabel, variableSymbol);
        else
            fprintf('  %s = %.10g    -> 常数项，与 %s / %s 无关\n', ...
                coeffLabel, coeff(idx), variableName, variableSymbol);
        end
    end

    fprintf('说明：%s 为输出响应，%s 为输入变量。\n', responseName, variableName);
end

function textStr = polynomialToString(coeff, variableSymbol)
% 将多项式系数向量转为便于显示的字符串。

    degree = numel(coeff) - 1;
    parts = strings(size(coeff));

    for i = 1:numel(coeff)
        currentCoeff = coeff(i);
        currentPower = degree - (i - 1);

        if currentPower > 1
            parts(i) = sprintf('%.6g*%s^%d', currentCoeff, variableSymbol, currentPower);
        elseif currentPower == 1
            parts(i) = sprintf('%.6g*%s', currentCoeff, variableSymbol);
        else
            parts(i) = sprintf('%.6g', currentCoeff);
        end
    end

    textStr = strjoin(parts, ' + ');
    textStr = strrep(textStr, '+ -', '- ');
end


