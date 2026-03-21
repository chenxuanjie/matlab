function results = identify_nomoto_stages(experimentRoot, opts)
% ======================== 输入配置区（可直接修改） ========================
%
% 运行模式：
% 'identify' -> 完整辨识（stage1 ~ stage4）
% 'validate' -> 只做 stage4 验证
runMode = 'identify';
%
% 是否启用角速度滤波：
% true  -> 先对 yaw_rate 做移动平均，再参与最小二乘拟合
% false -> 直接使用原始 yaw_rate 参与最小二乘拟合
useRateFilter = false;
%
% 验证模式参数（仅 runMode = 'validate' 时生效）：
% validateK:
%   单模型增益 K
%   对应模型：T * dr/dt + r + alpha * r^3 = K * u
%   例子：0.0061
validateK = NaN;
%
% validateT:
%   单模型时间常数 T
%   单位：秒，T 越大响应越慢
%   例子：0.46
validateT = NaN;
%
% validateAlpha:
%   单模型三次非线性参数 alpha
%   影响大角速度时的非线性程度
%   例子：0.22 或 -0.59（按你的辨识结果填写）
validateAlpha = NaN;
%
% 说明：
% 1. 默认数据目录：优先读取 Nomoto/experiment_tests
%    如果找不到完整阶段数据，会打印提示后回退到 origin_experiment_test
% 2. 直接点击运行时，会使用上面这组配置
% 3. 如果从命令行传入 experimentRoot / opts，则外部传入值优先
%
% ======================== 旧说明区（忽略） ========================
if false
%IDENTIFY_NOMOTO_STAGES 按阶段自动辨识 K、T、alpha 参数。
%
% 用法：
%   results = identify_nomoto_stages()
%   results = identify_nomoto_stages(experimentRoot)
%   results = identify_nomoto_stages(experimentRoot, opts)
%
% 采用模型：
%   T * dr/dt + r + alpha * r^3 = K * u
%
% 输入量定义：
%   u = (right_pwm - left_pwm) / 2
%
% 其中正值表示左电机减小、右电机增大。

% ======================== 常改项（优先看这里） ========================
% 1. 运行模式：
%    opts.Mode = 'identify'  -> 按 stage1~4 做完整辨识
%    opts.Mode = 'validate'  -> 只读取 stage4，用给定参数做验证
%
% 2. 数据目录：
%    experimentRoot 留空时，默认先读 Nomoto/experiment_tests；
%    如果 experiment_tests 中没有可用数据，会打印提示后回退到 origin_experiment_test。
%
% 3. 验证模式必填参数（单模型）：
%    opts.K
%    opts.T
%    opts.alpha
%
% 4. 其他常改项：
%    opts.ShowFigures      -> true/false，是否显示图
%    opts.OutputRoot       -> 结果输出目录
%    opts.RateFilterWindow -> 角速度移动平均窗口长度
%
% 5. 常用示例：
%    results = identify_nomoto_stages('', struct('Mode', 'identify', 'ShowFigures', false));
%    results = identify_nomoto_stages('', struct('Mode', 'validate', ...
%        'ShowFigures', true, 'K', 0.0061, 'T', 0.46, 'alpha', 0.22));
% ======================== 输入配置区（可直接修改） ========================
%
% 运行模式：
% 'identify' -> 完整辨识（stage1 ~ stage4）
% 'validate' -> 只做 stage4 验证，使用下面手填参数
runMode = 'identify';
%
% 数据来源模式：
% 'auto' -> 默认先读 Nomoto/experiment_tests；找不到完整数据再回退到 origin_experiment_test
% 'path' -> 使用下面 dataPath 指定的目录
dataSourceMode = 'auto';
%
% 当 dataSourceMode = 'path' 时生效：填写实验数据目录
dataPath = '';
%
% 是否显示图窗
showFigures = true;
%
% 是否额外保存 MATLAB 的 .fig 文件
saveMatFigures = false;
%
% 输出目录。留空表示使用脚本同目录下的 results 文件夹
outputRoot = '';
%
% 角速度移动平均滤波窗口长度。越大越平滑，但边沿会更钝
rateFilterWindow = 7;
%
% stage1 尾段比例与最少样本数
stage1TailFraction = 0.30;
stage1TailMinSamples = 30;
%
% 有效输入阈值与导数边界裁剪样本数
minInputAbs = 1.0;
derivativeTrimSamples = 1;
%
% 是否允许联合回退辨识
enableJointFallback = true;
%
% ======================== 验证模式参数区（仅 validate 生效） ========================
% 单模型验证参数：直接填 K / T / alpha
validateK = NaN;
validateT = NaN;
validateAlpha = NaN;
%
% 说明：
% 1. 直接点击运行时，脚本会使用上面这组配置。
% 2. 如果你从命令行传入 experimentRoot / opts，则外部传入值优先。
end

if nargin < 1
    experimentRoot = '';
end
if nargin < 2 || isempty(opts)
    opts = struct();
    opts.Mode = runMode;
    opts.EnableRateFilter = useRateFilter;
    opts.ShowFigures = true;
    opts.SaveMatFigures = false;
    opts.RateFilterWindow = 7;
    opts.Stage1TailFraction = 0.30;
    opts.Stage1TailMinSamples = 30;
    opts.MinInputAbs = 1.0;
    opts.DerivativeTrimSamples = 1;
    opts.EnableJointFallback = true;
    if isfinite(validateK)
        opts.K = validateK;
    end
    if isfinite(validateT)
        opts.T = validateT;
    end
    if isfinite(validateAlpha)
        opts.alpha = validateAlpha;
    end
end

scriptDir = fileparts(mfilename('fullpath'));
cfg = buildConfig(scriptDir, experimentRoot, opts);
ensureFolder(cfg.OutputRoot);
ensureFolder(cfg.RunOutputRoot);

 [catalog, resolvedSearchRoot] = discoverStageCsvFiles(cfg);
if ~isempty(resolvedSearchRoot)
    cfg.SearchRoot = resolvedSearchRoot;
end
if isempty(catalog)
    error(['未找到可用于辨识的阶段 CSV 文件。' ...
        '请检查 experiment_tests 文件夹，或显式传入搜索路径。']);
end

requestedStageIds = getRequestedStageIds(cfg);
selectedFiles = selectLatestStageFiles(catalog, requestedStageIds);
if isempty(selectedFiles)
    error('没有选中 stage 1-4 的 CSV 文件，无法进行辨识。');
end

fprintf('本次选中的阶段文件如下：%s\n', newline);
for i = 1:numel(selectedFiles)
    fprintf('  阶段 %d -> %s\n', selectedFiles(i).stageId, selectedFiles(i).filePath);
end

if isValidationMode(cfg)
    params = initializeValidationParams(cfg);
else
    cached = loadLatestCache(cfg.CacheFile);
    params = initializeParams(cfg, cached);
end

results = struct();
results.generated_at = char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'));
results.run_mode = cfg.Mode;
results.search_root = cfg.SearchRoot;
results.output_root = cfg.RunOutputRoot;
results.selected_files = struct([]);
results.stage_results = struct();
results.initial_params = paramsToStruct(params);

stageOrder = sort([selectedFiles.stageId]);
for i = 1:numel(selectedFiles)
    results.selected_files(i).stage_id = selectedFiles(i).stageId;
    results.selected_files(i).file_path = selectedFiles(i).filePath;
    results.selected_files(i).file_timestamp = selectedFiles(i).timestampLabel;
end

for i = 1:numel(stageOrder)
    stageId = stageOrder(i);
    selected = selectedFiles([selectedFiles.stageId] == stageId);
    data = readStageData(selected.filePath, cfg);

    stageFolder = fullfile(cfg.RunOutputRoot, sprintf('stage%d', stageId));
    ensureFolder(stageFolder);

    overviewFiles = plotCommonFigures(data, stageFolder, cfg);

    switch stageId
        case 1
            stageResult = identifyStage1K(data, stageFolder, cfg);
            params.K = stageResult.K;
            params.SourceK = 'stage1';
        case 2
            [stageResult, params] = identifyStage2T(data, params, stageFolder, cfg);
        case 3
            [stageResult, params] = identifyStage3Alpha(data, params, stageFolder, cfg);
        case 4
            stageResult = validateStage4(data, params, stageFolder, cfg);
        otherwise
            error('暂不支持的 stage_id：%d', stageId);
    end

    stageResult.file_path = selected.filePath;
    stageResult.stage_name = data.stageName;
    stageResult.common_figures = overviewFiles;
    results.stage_results.(sprintf('stage%d', stageId)) = stageResult;
    results.params_after_stage.(sprintf('stage%d', stageId)) = paramsToStruct(params); %#ok<STRNU>
end

results.final_params = paramsToStruct(params);
results.stage_order = stageOrder;
results.summary_files = saveSummaryArtifacts(results, cfg);

if isIdentifyMode(cfg)
    save(cfg.CacheFile, 'results');
end

fprintf('\n辨识结果汇总：\n');
fprintf('  K     = %.12g\n', results.final_params.K);
fprintf('  T     = %.12g\n', results.final_params.T);
fprintf('  alpha = %.12g\n', results.final_params.alpha);
fprintf('  输出目录: %s\n', cfg.RunOutputRoot);
end

function cfg = buildConfig(scriptDir, experimentRoot, opts)
cfg = struct();
cfg.ScriptDir = scriptDir;
cfg.ProjectRoot = fileparts(scriptDir);

if nargin < 2 || isempty(experimentRoot)
    cfg.UseExplicitSearchRoot = false;
    cfg.SearchRoot = cfg.ProjectRoot;
else
    cfg.UseExplicitSearchRoot = true;
    cfg.SearchRoot = char(string(experimentRoot));
end

if ~isfolder(cfg.SearchRoot)
    error('搜索根目录不存在：%s', cfg.SearchRoot);
end

cfg.OutputRoot = getOption(opts, 'OutputRoot', fullfile(scriptDir, 'results'));
cfg.OutputRoot = char(string(cfg.OutputRoot));
cfg.RunStamp = char(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));
cfg.RunOutputRoot = fullfile(cfg.OutputRoot, ['run_' cfg.RunStamp]);
cfg.CacheFile = fullfile(cfg.OutputRoot, 'nomoto_latest_results.mat');

% 常改 1：运行模式。'identify' 为完整辨识，'validate' 为只做 stage4 验证。
cfg.Mode = parseRunMode(getOption(opts, 'Mode', 'identify'));

% 常改 2：是否显示图窗。
cfg.ShowFigures = logical(getOption(opts, 'ShowFigures', true));
% 常改 3：是否额外保存 MATLAB 的 .fig 文件。
cfg.SaveMatFigures = logical(getOption(opts, 'SaveMatFigures', false));
% 常改 4：缺少前置参数时，是否允许联合回退辨识。
cfg.EnableJointFallback = logical(getOption(opts, 'EnableJointFallback', true));
% 常改 5：是否启用角速度移动平均滤波。
cfg.EnableRateFilter = logical(getOption(opts, 'EnableRateFilter', true));
% 常改 5：角速度滤波窗口。越大越平滑，但会更钝化边沿。
cfg.RateFilterWindow = max(1, round(getOption(opts, 'RateFilterWindow', 7)));
% 常改 6：stage1 尾段取样比例和最少样本数。
cfg.Stage1TailFraction = getOption(opts, 'Stage1TailFraction', 0.30);
cfg.Stage1TailMinSamples = max(10, round(getOption(opts, 'Stage1TailMinSamples', 30)));
% 常改 7：有效输入阈值与导数边界裁剪。
cfg.MinInputAbs = getOption(opts, 'MinInputAbs', 1.0);
cfg.DerivativeTrimSamples = max(0, round(getOption(opts, 'DerivativeTrimSamples', 1)));
cfg.LineWidth = 1.3;

% 验证模式常改 8：直接在 opts 里填 K/T/alpha。
cfg.OverrideK = getNumericOption(opts, 'K', NaN);
cfg.OverrideT = getNumericOption(opts, 'T', NaN);
cfg.OverrideAlpha = getNumericOption(opts, 'alpha', NaN);
end

function [catalog, resolvedSearchRoot] = discoverStageCsvFiles(cfg)
catalog = struct([]);
resolvedSearchRoot = '';

if cfg.UseExplicitSearchRoot
    catalog = collectStageCsvFiles(cfg.SearchRoot);
    resolvedSearchRoot = cfg.SearchRoot;
    return;
end

experimentRoot = fullfile(cfg.ProjectRoot, 'experiment_tests');
originRoot = fullfile(cfg.ProjectRoot, 'origin_experiment_test');

requiredStageIds = getRequestedStageIds(cfg);

experimentCatalog = collectStageCsvFiles(experimentRoot);
if hasRequiredStageSet(experimentCatalog, requiredStageIds)
    catalog = experimentCatalog;
    resolvedSearchRoot = experimentRoot;
    return;
end

fprintf('未在 experiment_tests 中找到当前模式所需的阶段 CSV，回退到 origin_experiment_test。\n');

originCatalog = collectStageCsvFiles(originRoot);
if ~isempty(originCatalog)
    catalog = originCatalog;
    resolvedSearchRoot = originRoot;
end
end

function catalog = collectStageCsvFiles(searchRoot)
catalog = struct([]);
if ~isfolder(searchRoot)
    return;
end

entries = dir(fullfile(searchRoot, '**', '*.csv'));
if isempty(entries)
    return;
end

for i = 1:numel(entries)
    filePath = fullfile(entries(i).folder, entries(i).name);
    meta = inspectStageCsv(filePath, entries(i));
    if isempty(meta)
        continue;
    end
    if isempty(catalog)
        catalog = meta;
    else
        catalog(end + 1) = meta; %#ok<AGROW>
    end
end
end

function tf = hasRequiredStageSet(catalog, stageIds)
if isempty(catalog)
    tf = false;
    return;
end

stages = unique([catalog.stageId]);
tf = all(ismember(stageIds, stages));
end

function meta = inspectStageCsv(filePath, dirEntry)
meta = struct([]);

try
    tbl = readtable(filePath, 'TextType', 'string');
catch
    return;
end

names = normalizeNames(tbl.Properties.VariableNames);
requiredNames = {'elapsed_time_s', 'yaw_rate_deg_s', 'left_pwm', 'right_pwm'};
for i = 1:numel(requiredNames)
    if ~any(strcmp(names, requiredNames{i}))
        return;
    end
end

stageId = NaN;
if any(strcmp(names, 'stage_id'))
    stageValues = numericColumn(tbl, names, {'stage_id'}, true);
    stageValues = stageValues(isfinite(stageValues));
    if ~isempty(stageValues)
        stageId = round(mode(stageValues));
    end
end

if ~(isfinite(stageId) && any(stageId == 1:4))
    token = regexp(lower(filePath), 'stage([1-4])', 'tokens', 'once');
    if ~isempty(token)
        stageId = str2double(token{1});
    end
end

if ~(isfinite(stageId) && any(stageId == 1:4))
    return;
end

timestampText = extractTimestampText(filePath);
if isempty(timestampText)
    dt = datetime(dirEntry.datenum, 'ConvertFrom', 'datenum');
    timestampValue = posixtime(dt);
    timestampLabel = char(datetime(dt, 'Format', 'yyyy-MM-dd HH:mm:ss'));
else
    dt = datetime(timestampText, 'InputFormat', 'yyyyMMdd_HHmmss');
    timestampValue = posixtime(dt);
    timestampLabel = timestampText;
end

meta = struct();
meta.stageId = stageId;
meta.filePath = filePath;
meta.fileName = dirEntry.name;
meta.timestampValue = timestampValue;
meta.timestampLabel = timestampLabel;
end

function selected = selectLatestStageFiles(catalog, stageIds)
if nargin < 2 || isempty(stageIds)
    stageIds = 1:4;
end

selected = struct([]);
for stageId = stageIds
    matches = catalog([catalog.stageId] == stageId);
    if isempty(matches)
        continue;
    end
    [~, idx] = max([matches.timestampValue]);
    if isempty(selected)
        selected = matches(idx);
    else
        selected(end + 1) = matches(idx); %#ok<AGROW>
    end
end
end

function stageIds = getRequestedStageIds(cfg)
if isValidationMode(cfg)
    stageIds = 4;
else
    stageIds = 1:4;
end
end

function tf = isIdentifyMode(cfg)
tf = strcmp(cfg.Mode, 'identify');
end

function tf = isValidationMode(cfg)
tf = strcmp(cfg.Mode, 'validate');
end

function data = readStageData(filePath, cfg)
tbl = readtable(filePath, 'TextType', 'string');
names = normalizeNames(tbl.Properties.VariableNames);

timeS = numericColumn(tbl, names, {'elapsed_time_s', 'elapsed_time', 'time_s', 'time'}, true);
timestamp = numericColumn(tbl, names, {'timestamp'}, false);
if isempty(timeS)
    if isempty(timestamp)
        error('文件中未找到时间列：%s', filePath);
    end
    timeS = timestamp - timestamp(1);
end

leftPwm = numericColumn(tbl, names, {'left_pwm'}, true);
rightPwm = numericColumn(tbl, names, {'right_pwm'}, true);
yawRateDegS = numericColumn(tbl, names, {'yaw_rate_deg_s', 'yaw_rate_degps', 'yaw_rate', 'r'}, true);
headingDeg = numericColumn(tbl, names, {'heading_deg'}, false);
relativeHeadingDeg = numericColumn(tbl, names, {'relative_heading_deg'}, false);
accumTurnDeg = numericColumn(tbl, names, {'accumulated_turn_deg'}, false);
speedMps = numericColumn(tbl, names, {'speed_mps', 'speed'}, false);
longitude = numericColumn(tbl, names, {'longitude', 'lon'}, false);
latitude = numericColumn(tbl, names, {'latitude', 'lat'}, false);
stageIdCol = numericColumn(tbl, names, {'stage_id'}, false);
stageNameCol = textColumn(tbl, names, {'stage_name'}, false);

sampleCount = numel(timeS);
if isempty(stageNameCol)
    stageNameCol = strings(sampleCount, 1);
end

[timeS, order] = sort(columnVector(timeS));
leftPwm = reorderAndColumn(leftPwm, order);
rightPwm = reorderAndColumn(rightPwm, order);
yawRateDegS = reorderAndColumn(yawRateDegS, order);
headingDeg = reorderAndColumn(headingDeg, order);
relativeHeadingDeg = reorderAndColumn(relativeHeadingDeg, order);
accumTurnDeg = reorderAndColumn(accumTurnDeg, order);
speedMps = reorderAndColumn(speedMps, order);
longitude = reorderAndColumn(longitude, order);
latitude = reorderAndColumn(latitude, order);
stageIdCol = reorderAndColumn(stageIdCol, order);
stageNameCol = reorderAndColumn(stageNameCol, order);

validMask = isfinite(timeS) & isfinite(leftPwm) & isfinite(rightPwm) & isfinite(yawRateDegS);
timeS = timeS(validMask);
leftPwm = leftPwm(validMask);
rightPwm = rightPwm(validMask);
yawRateDegS = yawRateDegS(validMask);
headingDeg = cropOptional(headingDeg, validMask);
relativeHeadingDeg = cropOptional(relativeHeadingDeg, validMask);
accumTurnDeg = cropOptional(accumTurnDeg, validMask);
speedMps = cropOptional(speedMps, validMask);
longitude = cropOptional(longitude, validMask);
latitude = cropOptional(latitude, validMask);
stageIdCol = cropOptional(stageIdCol, validMask);
stageNameCol = cropOptional(stageNameCol, validMask);

[timeS, uniqueIdx] = unique(timeS, 'stable');
leftPwm = leftPwm(uniqueIdx);
rightPwm = rightPwm(uniqueIdx);
yawRateDegS = yawRateDegS(uniqueIdx);
headingDeg = cropOptionalByIndex(headingDeg, uniqueIdx);
relativeHeadingDeg = cropOptionalByIndex(relativeHeadingDeg, uniqueIdx);
accumTurnDeg = cropOptionalByIndex(accumTurnDeg, uniqueIdx);
speedMps = cropOptionalByIndex(speedMps, uniqueIdx);
longitude = cropOptionalByIndex(longitude, uniqueIdx);
latitude = cropOptionalByIndex(latitude, uniqueIdx);
stageIdCol = cropOptionalByIndex(stageIdCol, uniqueIdx);
stageNameCol = cropOptionalByIndex(stageNameCol, uniqueIdx);

if isempty(timeS)
    error('预处理后没有剩余有效样本：%s', filePath);
end

timeS = timeS - timeS(1);
uPwm = 0.5 * (rightPwm - leftPwm);
uPwm = columnVector(uPwm);

yawRateRadS = deg2rad(columnVector(yawRateDegS));
if cfg.EnableRateFilter
    yawRateRadSFiltered = movmean(yawRateRadS, cfg.RateFilterWindow, 'Endpoints', 'shrink');
else
    yawRateRadSFiltered = yawRateRadS;
end
if numel(timeS) >= 3
    yawAccelRadS2 = gradient(yawRateRadSFiltered, timeS);
else
    yawAccelRadS2 = zeros(size(yawRateRadSFiltered));
end

headingRelDeg = buildRelativeHeading(headingDeg, relativeHeadingDeg, accumTurnDeg, yawRateDegS, timeS);
headingAbsDeg = buildAbsoluteHeading(headingDeg);

analysisMask = true(size(timeS));
trim = min(cfg.DerivativeTrimSamples, floor((numel(timeS) - 1) / 2));
if trim > 0
    analysisMask(1:trim) = false;
    analysisMask(end - trim + 1:end) = false;
end
analysisMask = analysisMask & isfinite(yawAccelRadS2) & isfinite(yawRateRadSFiltered);
analysisMask = analysisMask & (abs(uPwm) >= cfg.MinInputAbs);

stageId = NaN;
if ~isempty(stageIdCol)
    finiteStage = stageIdCol(isfinite(stageIdCol));
    if ~isempty(finiteStage)
        stageId = round(mode(finiteStage));
    end
end
if ~(isfinite(stageId) && any(stageId == 1:4))
    token = regexp(lower(filePath), 'stage([1-4])', 'tokens', 'once');
    if ~isempty(token)
        stageId = str2double(token{1});
    end
end

if isempty(stageNameCol) || all(stageNameCol == "")
    stageName = sprintf('stage%d', stageId);
else
    stageName = char(stageNameCol(find(stageNameCol ~= "", 1, 'first')));
end

data = struct();
data.filePath = filePath;
data.stageId = stageId;
data.stageName = stageName;
data.timeS = columnVector(timeS);
data.leftPwm = columnVector(leftPwm);
data.rightPwm = columnVector(rightPwm);
data.uPwm = uPwm;
data.yawRateDegS = columnVector(yawRateDegS);
data.yawRateRadS = yawRateRadS;
data.yawRateRadSFiltered = yawRateRadSFiltered;
data.yawAccelRadS2 = columnVector(yawAccelRadS2);
data.headingRelDeg = columnVector(headingRelDeg);
data.headingAbsDeg = columnVector(headingAbsDeg);
data.speedMps = optionalColumn(speedMps, numel(timeS));
data.longitude = optionalColumn(longitude, numel(timeS));
data.latitude = optionalColumn(latitude, numel(timeS));
data.analysisMask = columnVector(analysisMask);
data.dtMedian = median(diff(timeS));
data.sampleCount = numel(timeS);
end

function overviewFiles = plotCommonFigures(data, stageFolder, cfg)
style = plotStyle();
overviewFiles = struct();

fig = figure('Visible', figureVisibility(cfg), 'Color', 'w', ...
    'Name', sprintf('阶段%d总览', data.stageId));
tiledlayout(fig, 4, 1, 'Padding', 'compact', 'TileSpacing', 'compact');

nexttile;
plot(data.timeS, data.headingRelDeg, 'Color', style.headingColor, 'LineWidth', cfg.LineWidth);
applyAxesStyle(style);
xlabel('时间 (s)');
ylabel('航向角 (deg)');
title(sprintf('阶段%d 航向角随时间变化', data.stageId));

nexttile;
plot(data.timeS, data.uPwm, 'Color', style.inputColor, 'LineWidth', cfg.LineWidth);
applyAxesStyle(style);
xlabel('时间 (s)');
ylabel('半 PWM 差值');
title('半 PWM 差值随时间变化');

nexttile;
plot(data.timeS, data.yawRateDegS, '-', 'Color', style.measuredColor, 'LineWidth', 1.0);
hold on;
plot(data.timeS, rad2deg(data.yawRateRadSFiltered), '-', 'Color', style.fitColor, 'LineWidth', 1.2);
applyAxesStyle(style);
xlabel('时间 (s)');
ylabel('角速度 (deg/s)');
title('角速度随时间变化');
legend({'实测值', '滤波值'}, 'Location', 'best');
hold off;

nexttile;
if any(isfinite(data.speedMps))
    plot(data.timeS, data.speedMps, 'Color', style.speedColor, 'LineWidth', cfg.LineWidth);
    ylabel('线速度 (m/s)');
else
    plot(data.timeS, nan(size(data.timeS)), 'Color', style.speedColor, 'LineWidth', cfg.LineWidth);
    ylabel('线速度');
end
applyAxesStyle(style);
xlabel('时间 (s)');
title('线速度随时间变化');

overviewFiles.overview = saveFigureBundle(fig, fullfile(stageFolder, sprintf('stage%d_overview', data.stageId)), cfg);

if all(isfinite(data.longitude)) && all(isfinite(data.latitude))
    figMap = figure('Visible', figureVisibility(cfg), 'Color', 'w', ...
        'Name', sprintf('阶段%d 轨迹散点图', data.stageId));
    scatter(data.longitude, data.latitude, 18, data.timeS, 'filled');
    hold on;
    scatter(data.longitude(1), data.latitude(1), 60, 'g', 'filled');
    scatter(data.longitude(end), data.latitude(end), 60, 'r', 'filled');
    applyAxesStyle(style);
    axis equal;
    xlabel('经度');
    ylabel('纬度');
    title(sprintf('阶段%d 经纬度散点图', data.stageId));
    c = colorbar;
    ylabel(c, '时间 (s)');
    legend({'轨迹', '起点', '终点'}, 'Location', 'best');
    hold off;
    overviewFiles.gps = saveFigureBundle(figMap, fullfile(stageFolder, sprintf('stage%d_gps', data.stageId)), cfg);
else
    overviewFiles.gps = struct('eps', '', 'fig', '');
end
end

function stageResult = identifyStage1K(data, stageFolder, cfg)
style = plotStyle();
tailCount = max(cfg.Stage1TailMinSamples, ceil(cfg.Stage1TailFraction * data.sampleCount));
tailCount = min(tailCount, data.sampleCount);
tailIdx = (data.sampleCount - tailCount + 1):data.sampleCount;

uTail = data.uPwm(tailIdx);
rTail = data.yawRateRadSFiltered(tailIdx);
den = sum(uTail .* uTail);
if den <= eps
    error('阶段1的输入幅值过小，无法稳定辨识 K。');
end

K = sum(uTail .* rTail) / den;
rTailHat = K * uTail;
rSteadyHat = K * mean(uTail);

stageResult = struct();
stageResult.method = 'steady_tail_least_squares';
stageResult.K = K;
stageResult.tail_sample_count = tailCount;
stageResult.mean_half_pwm = mean(uTail);
stageResult.mean_yaw_rate_deg_s = rad2deg(mean(rTail));
stageResult.steady_yaw_rate_hat_deg_s = rad2deg(rSteadyHat);
stageResult.rmse_tail_rad_s = nomoto_utils.rmse(rTail, rTailHat);
stageResult.r2_tail = nomoto_utils.rsquared(rTail, rTailHat);

fig = figure('Visible', figureVisibility(cfg), 'Color', 'w', 'Name', '阶段1-K辨识');
tiledlayout(fig, 2, 1, 'Padding', 'compact', 'TileSpacing', 'compact');

nexttile;
plot(data.timeS, data.yawRateDegS, '-', 'Color', style.measuredColor, 'LineWidth', 1.0);
hold on;
plot(data.timeS, rad2deg(data.yawRateRadSFiltered), '-', 'Color', style.fitColor, 'LineWidth', 1.1);
xline(data.timeS(tailIdx(1)), '--', 'Color', style.referenceColor, 'LineWidth', 1.0);
yline(rad2deg(rSteadyHat), '--', 'Color', style.inputColor, 'LineWidth', 1.0);
applyAxesStyle(style);
xlabel('时间 (s)');
ylabel('角速度 (deg/s)');
title(sprintf('阶段1 线性稳态关系 K 辨识结果，K = %.6g', K));
legend({'实测值', '滤波值', '尾段起点', '稳态拟合值'}, 'Location', 'best');
hold off;

nexttile;
scatter(uTail, rad2deg(rTail), 18, style.pointColor, 'filled');
hold on;
xFit = linspace(min(uTail), max(uTail), 100).';
if isscalar(unique(uTail))
    xFit = linspace(min(uTail) - 5, max(uTail) + 5, 100).';
end
plot(xFit, rad2deg(K * xFit), '-', 'Color', style.fitColor, 'LineWidth', 1.3);
applyAxesStyle(style);
xlabel('半 PWM 差值');
ylabel('角速度 (deg/s)');
title('阶段1 线性稳态尾段样本与最小二乘拟合');
legend({'尾段样本', 'r = K u'}, 'Location', 'best');
hold off;

stageResult.figure = saveFigureBundle(fig, fullfile(stageFolder, 'stage1_identification_K'), cfg);
end

function [stageResult, params] = identifyStage2T(data, params, stageFolder, cfg)
style = plotStyle();
u = data.uPwm;
r = data.yawRateRadSFiltered;
drdt = data.yawAccelRadS2;
mask = data.analysisMask;

requireSamples(mask, 8, 'stage 2');

stageResult = struct();
if isfinite(params.K)
    basis = drdt(mask);
    rhs = params.K * u(mask) - r(mask);
    den = sum(basis .* basis);
    if den <= eps
        error('阶段2的角速度导数信息过弱，无法稳定辨识 T。');
    end
    T = sum(basis .* rhs) / den;
    stageResult.method = 'sequential_least_squares_known_K';
else
    if ~cfg.EnableJointFallback
        error('阶段2需要已知 K，但当前没有可用的 K，且未启用联合回退辨识。');
    end
    A = [u(mask), -drdt(mask)];
    x = A \ r(mask);
    params.K = x(1);
    params.SourceK = 'stage2_joint';
    T = x(2);
    stageResult.method = 'joint_least_squares_K_T';
    stageResult.K_from_joint_fit = params.K;
end

params.T = T;
params.SourceT = 'stage2';

rModel = nomoto_utils.simulateLinearNomoto(data.timeS, u, params.K, T, r(1));
headingModelDeg = cumtrapz(data.timeS, rad2deg(rModel));

stageResult.K = params.K;
stageResult.T = T;
stageResult.equation_rmse_rad_s = nomoto_utils.rmse(r(mask), params.K * u(mask) - T * drdt(mask));
stageResult.yaw_rate_rmse_deg_s = rad2deg(nomoto_utils.rmse(r, rModel));
stageResult.yaw_rate_r2 = nomoto_utils.rsquared(r, rModel);
stageResult.heading_rmse_deg = nomoto_utils.rmse(data.headingRelDeg, headingModelDeg);
stageResult.heading_r2 = nomoto_utils.rsquared(data.headingRelDeg, headingModelDeg);

fig = figure('Visible', figureVisibility(cfg), 'Color', 'w', 'Name', '阶段2-T辨识');
tiledlayout(fig, 2, 1, 'Padding', 'compact', 'TileSpacing', 'compact');

nexttile;
plot(data.timeS, data.yawRateDegS, '-', 'Color', style.measuredColor, 'LineWidth', 1.0);
hold on;
plot(data.timeS, rad2deg(rModel), '-', 'Color', style.fitColor, 'LineWidth', 1.25);
applyAxesStyle(style);
xlabel('时间 (s)');
ylabel('角速度 (deg/s)');
title(sprintf('阶段2 线性模型 T 辨识结果，K = %.6g，T = %.6g', params.K, T));
legend({'实测值', '线性模型'}, 'Location', 'best');
hold off;

nexttile;
plot(data.timeS, data.headingRelDeg, '-', 'Color', style.measuredColor, 'LineWidth', 1.0);
hold on;
plot(data.timeS, headingModelDeg, '-', 'Color', style.fitColor, 'LineWidth', 1.25);
applyAxesStyle(style);
xlabel('时间 (s)');
ylabel('航向角 (deg)');
title('阶段2 线性模型航向角拟合对比');
legend({'实测值', '线性模型'}, 'Location', 'best');
hold off;

stageResult.figure = saveFigureBundle(fig, fullfile(stageFolder, 'stage2_identification_T'), cfg);
end

function [stageResult, params] = identifyStage3Alpha(data, params, stageFolder, cfg)
style = plotStyle();
u = data.uPwm;
r = data.yawRateRadSFiltered;
drdt = data.yawAccelRadS2;
mask = data.analysisMask;

requireSamples(mask, 8, 'stage 3');

stageResult = struct();
missingK = ~isfinite(params.K);
missingT = ~isfinite(params.T);

if ~missingK && ~missingT
    basis = r(mask) .^ 3;
    rhs = params.K * u(mask) - r(mask) - params.T * drdt(mask);
    den = sum(basis .* basis);
    if den <= eps
        error('阶段3中的三次项信息过弱，无法稳定辨识 alpha。');
    end
    alpha = sum(basis .* rhs) / den;
    stageResult.method = 'sequential_least_squares_known_K_T';
elseif ~cfg.EnableJointFallback
    error('阶段3缺少前置参数，且未启用联合回退辨识。');
elseif ~missingK && missingT
    A = [drdt(mask), r(mask) .^ 3];
    x = A \ (params.K * u(mask) - r(mask));
    params.T = x(1);
    alpha = x(2);
    params.SourceT = 'stage3_joint';
    stageResult.method = 'joint_least_squares_T_alpha_with_known_K';
elseif missingK && ~missingT
    A = [u(mask), -r(mask) .^ 3];
    x = A \ (r(mask) + params.T * drdt(mask));
    params.K = x(1);
    alpha = x(2);
    params.SourceK = 'stage3_joint';
    stageResult.method = 'joint_least_squares_K_alpha_with_known_T';
else
    A = [u(mask), -drdt(mask), -r(mask) .^ 3];
    x = A \ r(mask);
    params.K = x(1);
    params.T = x(2);
    alpha = x(3);
    params.SourceK = 'stage3_joint';
    params.SourceT = 'stage3_joint';
    stageResult.method = 'joint_least_squares_K_T_alpha';
end

params.alpha = alpha;
params.SourceAlpha = 'stage3';

rNonlinear = nomoto_utils.simulateNonlinearNomoto(data.timeS, u, params.K, params.T, alpha, r(1));
headingNonlinearDeg = cumtrapz(data.timeS, rad2deg(rNonlinear));

stageResult.K = params.K;
stageResult.T = params.T;
stageResult.alpha = alpha;
stageResult.yaw_rate_rmse_deg_s = rad2deg(nomoto_utils.rmse(r, rNonlinear));
stageResult.yaw_rate_r2 = nomoto_utils.rsquared(r, rNonlinear);
stageResult.heading_rmse_deg = nomoto_utils.rmse(data.headingRelDeg, headingNonlinearDeg);
stageResult.heading_r2 = nomoto_utils.rsquared(data.headingRelDeg, headingNonlinearDeg);

fig = figure('Visible', figureVisibility(cfg), 'Color', 'w', 'Name', '阶段3-alpha辨识');
tiledlayout(fig, 2, 1, 'Padding', 'compact', 'TileSpacing', 'compact');

nexttile;
plot(data.timeS, data.yawRateDegS, '-', 'Color', style.measuredColor, 'LineWidth', 1.0);
hold on;
plot(data.timeS, rad2deg(rNonlinear), '-', 'Color', style.fitColor, 'LineWidth', 1.25);
applyAxesStyle(style);
xlabel('时间 (s)');
ylabel('角速度 (deg/s)');
title(sprintf('阶段3 alpha 辨识结果，K = %.6g，T = %.6g，alpha = %.6g', ...
    params.K, params.T, alpha));
legend({'实测值', '非线性模型'}, 'Location', 'best');
hold off;

nexttile;
plot(data.timeS, data.headingRelDeg, '-', 'Color', style.measuredColor, 'LineWidth', 1.0);
hold on;
plot(data.timeS, headingNonlinearDeg, '-', 'Color', style.fitColor, 'LineWidth', 1.25);
applyAxesStyle(style);
xlabel('时间 (s)');
ylabel('航向角 (deg)');
title('阶段3 航向角对比');
legend({'实测值', '非线性模型'}, 'Location', 'best');
hold off;

stageResult.figure = saveFigureBundle(fig, fullfile(stageFolder, 'stage3_identification_alpha'), cfg);
end

function stageResult = validateStage4(data, params, stageFolder, cfg)
style = plotStyle();
if ~(isfinite(params.K) && isfinite(params.T) && isfinite(params.alpha))
    error('阶段4非线性模型验证需要已知 K、T、alpha。');
end

u = data.uPwm;
r0 = data.yawRateRadSFiltered(1);
rNonlinear = nomoto_utils.simulateNonlinearNomoto(data.timeS, u, params.K, params.T, params.alpha, r0);
headingNonlinearDeg = cumtrapz(data.timeS, rad2deg(rNonlinear));
headingErrorDeg = data.headingRelDeg - headingNonlinearDeg;

stageResult = struct();
stageResult.method = 'model_validation';
stageResult.K = params.K;
stageResult.T = params.T;
stageResult.alpha = params.alpha;
stageResult.yaw_rate_rmse_deg_s = rad2deg(nomoto_utils.rmse(data.yawRateRadSFiltered, rNonlinear));
stageResult.yaw_rate_r2 = nomoto_utils.rsquared(data.yawRateRadSFiltered, rNonlinear);
stageResult.heading_rmse_deg = nomoto_utils.rmse(data.headingRelDeg, headingNonlinearDeg);
stageResult.heading_r2 = nomoto_utils.rsquared(data.headingRelDeg, headingNonlinearDeg);
stageResult.heading_error_max_abs_deg = max(abs(headingErrorDeg));

fig = figure('Visible', figureVisibility(cfg), 'Color', 'w', 'Name', '阶段4模型验证');
tiledlayout(fig, 2, 1, 'Padding', 'compact', 'TileSpacing', 'compact');

nexttile;
plot(data.timeS, data.yawRateDegS, '-', 'Color', style.measuredColor, 'LineWidth', 1.0);
hold on;
plot(data.timeS, rad2deg(rNonlinear), '-', 'Color', style.fitColor, 'LineWidth', 1.25);
applyAxesStyle(style);
xlabel('时间 (s)');
ylabel('角速度 (deg/s)');
title('阶段4 角速度验证');
legend({'实测值', '非线性模型'}, 'Location', 'best');
hold off;

nexttile;
plot(data.timeS, data.headingRelDeg, '-', 'Color', style.measuredColor, 'LineWidth', 1.0);
hold on;
plot(data.timeS, headingNonlinearDeg, '-', 'Color', style.fitColor, 'LineWidth', 1.25);
applyAxesStyle(style);
xlabel('时间 (s)');
ylabel('航向角 (deg)');
title('阶段4 航向角验证');
legend({'实测值', '非线性模型'}, 'Location', 'best');
hold off;

stageResult.figure = saveFigureBundle(fig, fullfile(stageFolder, 'stage4_validation'), cfg);

figErr = figure('Visible', figureVisibility(cfg), 'Color', 'w', 'Name', '阶段4航向角误差');
plot(data.timeS, headingErrorDeg, '-', 'Color', style.fitColor, 'LineWidth', 1.25);
hold on;
yline(0, '--', 'Color', style.referenceColor, 'LineWidth', 1.0);
applyAxesStyle(style);
xlabel('时间 (s)');
ylabel('航向角误差 (deg)');
title(sprintf('阶段4 航向角误差（实测 - 模型），RMSE = %.3f deg', stageResult.heading_rmse_deg));
legend({'航向角误差', '零误差参考线'}, 'Location', 'best');
hold off;

stageResult.heading_error_figure = saveFigureBundle(figErr, fullfile(stageFolder, 'stage4_heading_error'), cfg);
end

function saved = saveSummaryArtifacts(results, cfg)
saved = struct();

matPath = fullfile(cfg.RunOutputRoot, 'nomoto_identification_results.mat');
jsonPath = fullfile(cfg.RunOutputRoot, 'nomoto_identification_results.json');
txtPath = fullfile(cfg.RunOutputRoot, 'nomoto_identification_summary.txt');

save(matPath, 'results');

jsonText = jsonencode(results, PrettyPrint=true);
writeTextFile(jsonPath, jsonText);

summaryLines = {
    sprintf('生成时间：%s', results.generated_at)
    sprintf('搜索目录：%s', results.search_root)
    sprintf('输出目录：%s', results.output_root)
    sprintf('K 参数：%.12g', results.final_params.K)
    sprintf('T 参数：%.12g', results.final_params.T)
    sprintf('alpha 参数：%.12g', results.final_params.alpha)
    ''
    '本次选中的文件：'
    };

for i = 1:numel(results.selected_files)
    summaryLines{end + 1, 1} = sprintf('  阶段 %d -> %s', ...
        results.selected_files(i).stage_id, results.selected_files(i).file_path); %#ok<AGROW>
end

writeTextFile(txtPath, strjoin(summaryLines, newline));

saved.mat = matPath;
saved.json = jsonPath;
saved.txt = txtPath;
end

function params = initializeParams(cfg, cached)
params = struct();
params.K = NaN;
params.T = NaN;
params.alpha = NaN;
params.SourceK = '';
params.SourceT = '';
params.SourceAlpha = '';

if ~isempty(cached)
    if isfield(cached, 'final_params')
        if isfield(cached.final_params, 'K')
            params.K = cached.final_params.K;
            params.SourceK = 'cache';
        end
        if isfield(cached.final_params, 'T')
            params.T = cached.final_params.T;
            params.SourceT = 'cache';
        end
        if isfield(cached.final_params, 'alpha')
            params.alpha = cached.final_params.alpha;
            params.SourceAlpha = 'cache';
        end
    end
end

if isfinite(cfg.OverrideK)
    params.K = cfg.OverrideK;
    params.SourceK = 'override';
end
if isfinite(cfg.OverrideT)
    params.T = cfg.OverrideT;
    params.SourceT = 'override';
end
if isfinite(cfg.OverrideAlpha)
    params.alpha = cfg.OverrideAlpha;
    params.SourceAlpha = 'override';
end
end

function params = initializeValidationParams(cfg)
params = struct();
params.K = cfg.OverrideK;
params.T = cfg.OverrideT;
params.alpha = cfg.OverrideAlpha;
params.SourceK = 'validate_input';
params.SourceT = 'validate_input';
params.SourceAlpha = 'validate_input';

if ~(isfinite(params.K) && isfinite(params.T) && isfinite(params.alpha))
    error('验证模式要求显式提供 K、T、alpha。');
end
end

function cached = loadLatestCache(cacheFile)
cached = struct([]);
if ~isfile(cacheFile)
    return;
end
try
    data = load(cacheFile, 'results');
    if isfield(data, 'results')
        cached = data.results;
    end
catch
    cached = struct([]);
end
end

function out = paramsToStruct(params)
out = struct();
out.K = params.K;
out.T = params.T;
out.alpha = params.alpha;
out.K_source = params.SourceK;
out.T_source = params.SourceT;
out.alpha_source = params.SourceAlpha;
end

function headingRelDeg = buildRelativeHeading(headingDeg, relativeHeadingDeg, accumTurnDeg, yawRateDegS, timeS)
if ~isempty(relativeHeadingDeg) && any(isfinite(relativeHeadingDeg))
    headingRelDeg = columnVector(relativeHeadingDeg);
    headingRelDeg = headingRelDeg - headingRelDeg(1);
    return;
end

if ~isempty(accumTurnDeg) && any(isfinite(accumTurnDeg))
    headingRelDeg = columnVector(accumTurnDeg);
    headingRelDeg = headingRelDeg - headingRelDeg(1);
    return;
end

if ~isempty(headingDeg) && any(isfinite(headingDeg))
    headingRad = unwrap(deg2rad(columnVector(headingDeg)));
    headingRelDeg = rad2deg(headingRad - headingRad(1));
    return;
end

headingRelDeg = cumtrapz(timeS, yawRateDegS);
headingRelDeg = columnVector(headingRelDeg);
end

function headingAbsDeg = buildAbsoluteHeading(headingDeg)
if isempty(headingDeg) || ~any(isfinite(headingDeg))
    headingAbsDeg = [];
    return;
end
headingAbsDeg = columnVector(headingDeg);
end

function requireSamples(mask, minCount, stageName)
if nnz(mask) < minCount
    error('%s 可用有效样本不足，无法完成辨识。', stageName);
end
end

function style = plotStyle()
style = struct();
style.measuredColor = [0.18, 0.18, 0.18];
style.inputColor = [0.12, 0.45, 0.78];
style.fitColor = [0.82, 0.15, 0.10];
style.referenceColor = [0.42, 0.56, 0.70];
style.headingColor = [0.10, 0.52, 0.35];
style.speedColor = [0.65, 0.40, 0.12];
style.pointColor = [0.38, 0.20, 0.58];
end

function applyAxesStyle(~)
grid on;
box on;
ax = gca;
ax.LineWidth = 0.9;
ax.FontSize = 10;
ax.GridAlpha = 0.18;
ax.MinorGridAlpha = 0.08;
ax.XColor = [0.15, 0.15, 0.15];
ax.YColor = [0.15, 0.15, 0.15];
end

function saved = saveFigureBundle(fig, basePath, cfg)
saved = struct('eps', '', 'fig', '');
drawnow;

epsPath = [basePath '.eps'];
exportgraphics(fig, epsPath, 'ContentType', 'vector');
saved.eps = epsPath;

if cfg.SaveMatFigures
    figPath = [basePath '.fig'];
    savefig(fig, figPath);
    saved.fig = figPath;
end

if ~cfg.ShowFigures
    close(fig);
end
end

function modeText = figureVisibility(cfg)
if cfg.ShowFigures
    modeText = 'on';
else
    modeText = 'off';
end
end

function value = getOption(opts, fieldName, defaultValue)
if isfield(opts, fieldName) && ~isempty(opts.(fieldName))
    value = opts.(fieldName);
else
    value = defaultValue;
end
end

function value = getNumericOption(opts, fieldName, defaultValue)
value = getOption(opts, fieldName, defaultValue);
if isempty(value)
    value = defaultValue;
end
value = double(value);
if ~isscalar(value)
    error('选项 %s 必须为标量。', fieldName);
end
end

function modeText = parseRunMode(rawMode)
modeText = lower(strtrim(char(string(rawMode))));
switch modeText
    case {'identify', 'identification', 'fit', '辨识', '杈ㄨ瘑'}
        modeText = 'identify';
    case {'validate', 'validation', 'verify', '验证', '楠岃瘉'}
        modeText = 'validate';
    otherwise
        error('Mode only supports identify / validate.');
end
end

function ensureFolder(folderPath)
if ~isfolder(folderPath)
    mkdir(folderPath);
end
end

function names = normalizeNames(variableNames)
names = strings(size(variableNames));
for i = 1:numel(variableNames)
    name = lower(char(string(variableNames{i})));
    name = regexprep(name, '[^a-z0-9]+', '_');
    name = regexprep(name, '^_+|_+$', '');
    names(i) = string(name);
end
names = cellstr(names);
end

function values = numericColumn(tbl, normalizedNames, candidateNames, required)
if nargin < 4
    required = true;
end

idx = findColumnIndex(normalizedNames, candidateNames);
if isempty(idx)
    if required
        error('缺少必要列：%s', strjoin(candidateNames, ', '));
    else
        values = [];
        return;
    end
end

values = tbl{:, idx};
if iscell(values)
    values = str2double(values);
elseif isstring(values)
    values = str2double(values);
elseif ischar(values)
    values = str2double(cellstr(values));
elseif istable(values)
    values = table2array(values);
end
values = columnVector(values);
end

function values = textColumn(tbl, normalizedNames, candidateNames, required)
if nargin < 4
    required = true;
end

idx = findColumnIndex(normalizedNames, candidateNames);
if isempty(idx)
    if required
        error('缺少必要的文本列：%s', strjoin(candidateNames, ', '));
    else
        values = strings(0, 1);
        return;
    end
end

values = tbl{:, idx};
if iscell(values)
    values = string(values);
elseif ischar(values)
    values = string(cellstr(values));
elseif ~isstring(values)
    values = string(values);
end
values = columnVector(values);
end

function idx = findColumnIndex(normalizedNames, candidateNames)
idx = [];
for i = 1:numel(candidateNames)
    candidate = lower(candidateNames{i});
    candidate = regexprep(candidate, '[^a-z0-9]+', '_');
    candidate = regexprep(candidate, '^_+|_+$', '');
    match = find(strcmp(normalizedNames, candidate), 1, 'first');
    if ~isempty(match)
        idx = match;
        return;
    end
end
end

function x = columnVector(x)
if isempty(x)
    return;
end
x = x(:);
end

function arr = reorderAndColumn(arr, order)
if isempty(arr)
    arr = [];
    return;
end
arr = columnVector(arr);
arr = arr(order);
end

function arr = cropOptional(arr, mask)
if isempty(arr)
    return;
end
arr = columnVector(arr);
arr = arr(mask);
end

function arr = cropOptionalByIndex(arr, idx)
if isempty(arr)
    return;
end
arr = columnVector(arr);
arr = arr(idx);
end

function arr = optionalColumn(arr, count)
if isempty(arr)
    arr = nan(count, 1);
else
    arr = columnVector(arr);
end
end

function timestampText = extractTimestampText(filePath)
[~, name] = fileparts(filePath);
token = regexp(name, '(\d{8}_\d{6})$', 'tokens', 'once');
if isempty(token)
    timestampText = '';
else
    timestampText = token{1};
end
end

function writeTextFile(filePath, textBody)
fid = fopen(filePath, 'w', 'n', 'UTF-8');
if fid < 0
    error('无法写入文件：%s', filePath);
end
cleanup = onCleanup(@() fclose(fid)); %#ok<NASGU>
fprintf(fid, '%s', textBody);
end
