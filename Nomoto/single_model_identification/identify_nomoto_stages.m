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
useRateFilter = true;
%
% 是否显示图窗
showFigures = true;
%
% 是否额外保存 EPS 矢量图
saveEpsFigures = false;
%
% 输出目录。留空表示使用脚本同目录下的 results 文件夹
outputRoot = '';
%
% 直行修正所需的半 PWM 差值，逆时针为正
uTrim = 0;
%
% 角速度移动平均滤波窗口长度。越大越平滑，但边沿会更钝
rateFilterWindow = 7;
%
% stage1 稳态筛样参数。
% 1) 先去掉前面加速段：当 |r| 达到稳态中心值的该比例后，认为进入稳态
% 2) 再在后面保留落在稳态角速度范围内的样本
% 3) 最后按单次拟合残差剔除特别离谱的点
stage1SteadyEnterRatio = 0.85;
stage1SteadyRateTolDegS = 3.0;
stage1SteadyRateTolRatio = 0.15;
stage1ResidualTolDegS = 1.5;
stage1ResidualTolSigma = 3.0;
stage1SteadyMinSamples = 20;
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
% 验证模式参数（仅 runMode = 'validate' 时生效）：
% validateK:
%   单模型增益 K
%   对应模型：T * dr/dt + r + alpha * r^3 = K * (u - u_trim)
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

if nargin < 1
    experimentRoot = '';
end
if nargin < 2 || isempty(opts)
    opts = struct();
    opts.Mode = runMode;
    opts.EnableRateFilter = useRateFilter;
    opts.ShowFigures = showFigures;
    opts.SaveEpsFigures = saveEpsFigures;
    opts.RateFilterWindow = rateFilterWindow;
    opts.Stage1SteadyEnterRatio = stage1SteadyEnterRatio;
    opts.Stage1SteadyRateTolDegS = stage1SteadyRateTolDegS;
    opts.Stage1SteadyRateTolRatio = stage1SteadyRateTolRatio;
    opts.Stage1ResidualTolDegS = stage1ResidualTolDegS;
    opts.Stage1ResidualTolSigma = stage1ResidualTolSigma;
    opts.Stage1SteadyMinSamples = stage1SteadyMinSamples;
    opts.Stage1TailFraction = stage1TailFraction;
    opts.Stage1TailMinSamples = stage1TailMinSamples;
    opts.UTrim = uTrim;
    opts.MinInputAbs = minInputAbs;
    opts.DerivativeTrimSamples = derivativeTrimSamples;
    opts.EnableJointFallback = enableJointFallback;
    if ~isempty(outputRoot)
        opts.OutputRoot = outputRoot;
    end
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
fprintf('===== 非线性 Nomoto 辨识试验与验证 =====\n');

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
fprintf('  u_trim = %.12g\n', results.final_params.u_trim);
if isfield(results.stage_results, 'stage1') && isfield(results.stage_results.stage1, 'turning_radius_m') ...
        && isfinite(results.stage_results.stage1.turning_radius_m)
    fprintf('  stage1 回转半径 ≈ %.3f m（直径 ≈ %.3f m）\n', ...
        results.stage_results.stage1.turning_radius_m, results.stage_results.stage1.turning_diameter_m);
end
if isfield(results.stage_results, 'stage4') ...
        && isfield(results.stage_results.stage4, 'heading_error_min_deg') ...
        && isfield(results.stage_results.stage4, 'heading_error_max_deg') ...
        && isfinite(results.stage_results.stage4.heading_error_min_deg) ...
        && isfinite(results.stage_results.stage4.heading_error_max_deg)
    fprintf('  辨识误差：[%.4f,%.4f] deg\n', ...
        results.stage_results.stage4.heading_error_min_deg, ...
        results.stage_results.stage4.heading_error_max_deg);
end
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
% 常改 3：是否额外保存 EPS 矢量图。
cfg.SaveEpsFigures = logical(getOption(opts, 'SaveEpsFigures', false));
% 常改 4：缺少前置参数时，是否允许联合回退辨识。
cfg.EnableJointFallback = logical(getOption(opts, 'EnableJointFallback', true));
% 常改 5：是否启用角速度移动平均滤波。
cfg.EnableRateFilter = logical(getOption(opts, 'EnableRateFilter', true));
% 常改 5：角速度滤波窗口。越大越平滑，但会更钝化边沿。
cfg.RateFilterWindow = max(1, round(getOption(opts, 'RateFilterWindow', 7)));
% 常改 6：stage1 稳态筛样参数；尾段取样仅在筛样失败时回退。
cfg.Stage1SteadyEnterRatio = getOption(opts, 'Stage1SteadyEnterRatio', 0.85);
cfg.Stage1SteadyRateTolDegS = getOption(opts, 'Stage1SteadyRateTolDegS', 3.0);
cfg.Stage1SteadyRateTolRatio = getOption(opts, 'Stage1SteadyRateTolRatio', 0.15);
cfg.Stage1ResidualTolDegS = getOption(opts, 'Stage1ResidualTolDegS', 1.5);
cfg.Stage1ResidualTolSigma = getOption(opts, 'Stage1ResidualTolSigma', 3.0);
cfg.Stage1SteadyMinSamples = max(5, round(getOption(opts, 'Stage1SteadyMinSamples', 20)));
cfg.Stage1TailFraction = getOption(opts, 'Stage1TailFraction', 0.30);
cfg.Stage1TailMinSamples = max(10, round(getOption(opts, 'Stage1TailMinSamples', 30)));
cfg.UTrim = getOption(opts, 'UTrim', 0.0);
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
    tbl = readStageTable(filePath, { ...
        {'elapsed_time_s', 'elapsed_time', 'time_s', 'time', 'timestamp'}, ...
        {'yaw_rate_deg_s', 'yaw_rate_degps', 'yaw_rate', 'r'}, ...
        {'left_pwm'}, ...
        {'right_pwm'}});
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
tbl = readStageTable(filePath, { ...
    {'elapsed_time_s', 'elapsed_time', 'time_s', 'time', 'timestamp'}, ...
    {'yaw_rate_deg_s', 'yaw_rate_degps', 'yaw_rate', 'r'}, ...
    {'left_pwm'}, ...
    {'right_pwm'}});
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
uModelPwm = uPwm - cfg.UTrim;

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
analysisMask = analysisMask & (abs(uModelPwm) >= cfg.MinInputAbs);

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
data.uModelPwm = uModelPwm;
data.uTrim = cfg.UTrim;
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

function tbl = readStageTable(filePath, requiredColumnGroups)
if nargin < 2
    requiredColumnGroups = {};
end

[tblDefault, defaultErr] = tryReadStageTable(filePath, '');
defaultOk = isempty(defaultErr) && hasRequiredColumnGroups(tblDefault, requiredColumnGroups);
if defaultOk
    tbl = tblDefault;
    return;
end

[tblUtf8, utf8Err] = tryReadStageTable(filePath, 'UTF-8');
utf8Ok = isempty(utf8Err) && hasRequiredColumnGroups(tblUtf8, requiredColumnGroups);
if utf8Ok
    fprintf('检测到默认读取异常，改用 UTF-8 重读：%s\n', filePath);
    tbl = tblUtf8;
    return;
end

if isempty(defaultErr)
    tbl = tblDefault;
    return;
end

if isempty(utf8Err)
    tbl = tblUtf8;
    return;
end

error('读取数据文件失败：%s\n默认读取失败：%s\nUTF-8 重读失败：%s', ...
    filePath, defaultErr.message, utf8Err.message);
end

function [tbl, readErr] = tryReadStageTable(filePath, encodingName)
tbl = table();
readErr = [];

try
    if strlength(string(encodingName)) == 0
        tbl = readtable(filePath, 'TextType', 'string');
    else
        tbl = readtable(filePath, 'TextType', 'string', 'Encoding', char(string(encodingName)));
    end
catch err
    readErr = err;
end
end

function tf = hasRequiredColumnGroups(tbl, requiredColumnGroups)
if isempty(requiredColumnGroups)
    tf = true;
    return;
end

if ~istable(tbl) || width(tbl) == 0
    tf = false;
    return;
end

names = normalizeNames(tbl.Properties.VariableNames);
tf = true;
for i = 1:numel(requiredColumnGroups)
    candidateNames = requiredColumnGroups{i};
    if ischar(candidateNames) || isstring(candidateNames)
        candidateNames = cellstr(string(candidateNames));
    end
    if ~any(ismember(names, normalizeNames(candidateNames)))
        tf = false;
        return;
    end
end
end

function overviewFiles = plotCommonFigures(data, stageFolder, cfg)
style = plotStyle();
overviewFiles = struct();

fig = figure('Visible', figureVisibility(cfg), 'Color', 'w', ...
    'Name', sprintf('阶段%d总览', data.stageId));
tiledlayout(fig, 4, 1, 'Padding', 'compact', 'TileSpacing', 'compact');

nexttile;
plotDiscreteSeries(data.timeS, data.headingRelDeg, style.headingColor);
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
plotDiscreteSeries(data.timeS, data.yawRateDegS, style.measuredColor);
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
    plotDiscreteSeries(data.timeS, data.speedMps, style.speedColor);
    ylabel('线速度 (m/s)');
else
    plot(data.timeS, nan(size(data.timeS)), 'Color', style.speedColor, 'LineWidth', cfg.LineWidth);
    ylabel('线速度');
end
applyAxesStyle(style);
xlabel('时间 (s)');
title('线速度随时间变化');

overviewFiles.overview = saveFigureBundle(fig, fullfile(stageFolder, sprintf('stage%d_overview', data.stageId)), cfg);
overviewFiles.yaw_accel = struct('eps', '', 'fig', '');

if all(isfinite(data.longitude)) && all(isfinite(data.latitude))
    figMap = figure('Visible', figureVisibility(cfg), 'Color', 'w', ...
        'Name', sprintf('阶段%d 轨迹散点图', data.stageId));
    scatter(data.longitude, data.latitude, 18, data.timeS, 'filled');
    hold on;
    scatter(data.longitude(1), data.latitude(1), 60, 'g', 'filled');
    scatter(data.longitude(end), data.latitude(end), 60, 'r', 'filled');
    applyAxesStyle(style);
    axis equal;
    xlabel('经度 (°E)');
    ylabel('纬度 (°N)');
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
steadyInfo = selectStage1SteadySamples(data, cfg, 'all');
K = leastSquaresGain(steadyInfo.uSel, steadyInfo.rSel);
if ~isfinite(K)
    error('阶段1筛选后的稳态样本输入过小，无法稳定辨识 K。');
end
rSteadyHat = K * mean(steadyInfo.uSel);
rSelHat = K * steadyInfo.uSel;

stageResult = struct();
stageResult.method = 'steady_rate_band_fit';
stageResult.K = K;
stageResult.sample_count = numel(steadyInfo.selectedIdx);
stageResult.tail_sample_count = stageResult.sample_count;
stageResult.mean_half_pwm = mean(steadyInfo.uSel);
stageResult.mean_yaw_rate_deg_s = rad2deg(mean(steadyInfo.rSel));
stageResult.steady_yaw_rate_hat_deg_s = rad2deg(rSteadyHat);
stageResult.mean_speed_mps = meanFinite(steadyInfo.speedSel);
stageResult.turning_radius_m = estimateTurningRadius(stageResult.mean_speed_mps, mean(steadyInfo.rSel));
stageResult.turning_diameter_m = 2 * stageResult.turning_radius_m;
stageResult.rmse_tail_rad_s = nomoto_utils.rmse(steadyInfo.rSel, rSelHat);
stageResult.r2_tail = nomoto_utils.rsquared(steadyInfo.rSel, rSelHat);
stageResult.selection_mode = steadyInfo.mode;
stageResult.steady_center_deg_s = rad2deg(steadyInfo.rRef);
stageResult.steady_range_deg_s = rad2deg(steadyInfo.rateTol);
stageResult.steady_start_time_s = steadyInfo.startTime;
stageResult.residual_threshold_deg_s = rad2deg(steadyInfo.residualTol);
stageResult.residual_removed_count = steadyInfo.residualRemovedCount;
stageResult.residual_inlier_count = numel(steadyInfo.selectedIdx);

fig = figure('Visible', figureVisibility(cfg), 'Color', 'w', 'Name', '阶段1-K辨识');
tiledlayout(fig, 2, 1, 'Padding', 'compact', 'TileSpacing', 'compact');

nexttile;
hMeasured = plotDiscreteSeries(data.timeS, data.yawRateDegS, style.measuredColor);
hold on;
hFiltered = plot(data.timeS, rad2deg(data.yawRateRadSFiltered), '-', 'Color', style.fitColor, 'LineWidth', 1.1);
hSelected = scatter(data.timeS(steadyInfo.selectedIdx), rad2deg(data.yawRateRadSFiltered(steadyInfo.selectedIdx)), ...
    26, style.headingColor, 'filled', 'DisplayName', '筛选样本');
hStart = xline(steadyInfo.startTime, '--', 'Color', style.referenceColor, 'LineWidth', 1.0, ...
    'DisplayName', '进入稳态起点');
hCenter = yline(rad2deg(steadyInfo.rRef), '--', 'Color', style.inputColor, 'LineWidth', 1.0, ...
    'DisplayName', '稳态角速度中心');
applyAxesStyle(style);
xlabel('时间 (s)');
ylabel('角速度 (deg/s)');
title(sprintf('阶段1 稳态范围筛选，K = %.6g', K));
legend([hMeasured, hFiltered, hSelected, hStart, hCenter], ...
    {'实测值', '滤波值', '筛选样本', '进入稳态起点', '稳态角速度中心'}, 'Location', 'best');
hold off;

nexttile;
hFitPoints = scatter(steadyInfo.uSel, rad2deg(steadyInfo.rSel), 24, style.pointColor, 'filled');
hold on;
xFit = buildFitAxis(steadyInfo.uSel);
hFitLine = plot(xFit, rad2deg(K * xFit), '-', 'Color', style.fitColor, 'LineWidth', 1.3);
applyAxesStyle(style);
xlabel('修正后半 PWM 差值');
ylabel('角速度 (deg/s)');
title('阶段1 稳态样本与最小二乘拟合');
legend([hFitPoints, hFitLine], {'筛选样本', 'r = K (u-u_{trim})'}, 'Location', 'best');
hold off;

stageResult.figure = saveFigureBundle(fig, fullfile(stageFolder, 'stage1_identification_K'), cfg);
end

function steadyInfo = selectStage1SteadySamples(data, cfg, signMode)
timeS = columnVector(data.timeS);
u = columnVector(data.uModelPwm);
r = columnVector(data.yawRateRadSFiltered);
speedMps = columnVector(data.speedMps);
baseMask = columnVector(data.analysisMask);
baseMask = baseMask & isfinite(timeS) & isfinite(u) & isfinite(r);

switch lower(string(signMode))
    case "positive"
        baseMask = baseMask & (u > cfg.MinInputAbs);
    case "negative"
        baseMask = baseMask & (u < -cfg.MinInputAbs);
    otherwise
        baseMask = baseMask & (abs(u) >= cfg.MinInputAbs);
end

validIdx = find(baseMask);
if numel(validIdx) < 5
    error('阶段1有效样本不足，无法稳定辨识 K。');
end

tailCount = max(cfg.Stage1TailMinSamples, ceil(cfg.Stage1TailFraction * numel(validIdx)));
tailCount = min(tailCount, numel(validIdx));
tailIdx = validIdx(end - tailCount + 1:end);
if isempty(tailIdx)
    error('阶段1无法获得稳态中心值。');
end

rRef = median(r(tailIdx), 'omitnan');
if ~(isfinite(rRef) && abs(rRef) > eps)
    rRef = mean(r(tailIdx), 'omitnan');
end
if ~(isfinite(rRef) && abs(rRef) > eps)
    rRef = median(r(validIdx), 'omitnan');
end
if ~(isfinite(rRef) && abs(rRef) > eps)
    error('阶段1无法得到有效的稳态角速度中心值。');
end

enterThreshold = cfg.Stage1SteadyEnterRatio * abs(rRef);
rateTol = max(deg2rad(cfg.Stage1SteadyRateTolDegS), cfg.Stage1SteadyRateTolRatio * abs(rRef));

enterIdx = validIdx(find(abs(r(validIdx)) >= enterThreshold, 1, 'first'));
if isempty(enterIdx)
    enterIdx = tailIdx(1);
end

selectedIdx = validIdx(validIdx >= enterIdx & abs(r(validIdx) - rRef) <= rateTol);
mode = 'steady_rate_band';

if numel(selectedIdx) < cfg.Stage1SteadyMinSamples
    rateTol = 1.5 * rateTol;
    selectedIdx = validIdx(validIdx >= enterIdx & abs(r(validIdx) - rRef) <= rateTol);
    mode = 'steady_rate_band_relaxed';
end

if numel(selectedIdx) < max(5, min(cfg.Stage1SteadyMinSamples, numel(validIdx)))
    selectedIdx = tailIdx;
    mode = 'tail_fallback';
    rRef = median(r(selectedIdx), 'omitnan');
    rateTol = max(abs(r(selectedIdx) - rRef));
    enterIdx = selectedIdx(1);
end

[selectedIdx, residualInfo] = refineStage1ResidualSamples(u, r, selectedIdx, cfg);
if residualInfo.applied
    mode = [mode '_residual'];
end

steadyInfo = struct();
steadyInfo.mode = mode;
steadyInfo.selectedIdx = columnVector(selectedIdx);
steadyInfo.startTime = timeS(selectedIdx(1));
steadyInfo.rRef = rRef;
steadyInfo.rateTol = rateTol;
steadyInfo.residualTol = residualInfo.threshold;
steadyInfo.residualRemovedCount = residualInfo.removedCount;
steadyInfo.uSel = u(selectedIdx);
steadyInfo.rSel = r(selectedIdx);
steadyInfo.speedSel = speedMps(selectedIdx);
end

function [selectedIdx, residualInfo] = refineStage1ResidualSamples(u, r, selectedIdx, cfg)
selectedIdx = columnVector(selectedIdx);
residualInfo = struct('applied', false, 'threshold', NaN, 'removedCount', 0);
if numel(selectedIdx) < max(5, min(cfg.Stage1SteadyMinSamples, numel(selectedIdx)))
    return;
end

uSel = u(selectedIdx);
rSel = r(selectedIdx);
K0 = leastSquaresGain(uSel, rSel);
if ~isfinite(K0)
    return;
end

residual = rSel - K0 * uSel;
residualCenter = median(residual, 'omitnan');
residualMad = median(abs(residual - residualCenter), 'omitnan');
residualScale = 1.4826 * residualMad;
if ~(isfinite(residualScale) && residualScale > eps)
    residualScale = std(residual, 'omitnan');
end

threshold = max(deg2rad(cfg.Stage1ResidualTolDegS), cfg.Stage1ResidualTolSigma * residualScale);
if ~(isfinite(threshold) && threshold > 0)
    return;
end

inlierMask = abs(residual) <= threshold;
if all(inlierMask)
    residualInfo.threshold = threshold;
    return;
end

minKeep = max(5, min(cfg.Stage1SteadyMinSamples, numel(selectedIdx)));
if nnz(inlierMask) < minKeep
    return;
end

selectedIdx = selectedIdx(inlierMask);
residualInfo.applied = true;
residualInfo.threshold = threshold;
residualInfo.removedCount = nnz(~inlierMask);
end

function xFit = buildFitAxis(values)
values = columnVector(values);
values = values(isfinite(values));
if isempty(values)
    xFit = linspace(-1, 1, 100).';
    return;
end

vmin = min(values);
vmax = max(values);
if abs(vmax - vmin) < eps
    pad = max(5, 0.15 * max(abs(vmax), 1));
    xFit = linspace(vmin - pad, vmax + pad, 100).';
else
    pad = 0.08 * (vmax - vmin);
    xFit = linspace(vmin - pad, vmax + pad, 100).';
end
end

function value = leastSquaresGain(u, r)
u = columnVector(u);
r = columnVector(r);
den = sum(u .* u);
if den <= eps
    value = NaN;
else
    value = sum(u .* r) / den;
end
end

function [stageResult, params] = identifyStage2T(data, params, stageFolder, cfg)
style = plotStyle();
u = data.uModelPwm;
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

stage2FitX = drdt(mask);
stage2FitY = params.K * u(mask) - r(mask);
stage2FitXDeg = rad2deg(stage2FitX);
stage2FitYDeg = rad2deg(stage2FitY);
xMin = min(stage2FitXDeg);
xMax = max(stage2FitXDeg);
if abs(xMax - xMin) <= eps(max(1, max(abs(stage2FitXDeg))))
    xPad = max(1, 0.1 * max(1, abs(xMax)));
    xLine = linspace(xMin - xPad, xMax + xPad, 100).';
else
    xLine = linspace(xMin, xMax, 100).';
end
yLine = T * xLine;

figLsq = figure('Visible', figureVisibility(cfg), 'Color', 'w', 'Name', 'stage2_least_squares_fit');
scatter(stage2FitXDeg, stage2FitYDeg, 18, style.pointColor, 'filled');
hold on;
plot(xLine, yLine, '-', 'Color', style.fitColor, 'LineWidth', 1.3);
applyAxesStyle(style);
xlabel('角速度导数 dr/dt (deg/s^2)');
ylabel('K(u-u_{trim}) - r (deg/s)');
title(sprintf('阶段2 最小二乘拟合 T，斜率 = %.6g s', T));
legend({'有效样本', '最小二乘拟合'}, 'Location', 'best');
hold off;
stageResult.lsq_figure = saveFigureBundle(figLsq, fullfile(stageFolder, 'stage2_least_squares_fit'), cfg);

fig = figure('Visible', figureVisibility(cfg), 'Color', 'w', 'Name', '阶段2-T辨识');
tiledlayout(fig, 2, 1, 'Padding', 'compact', 'TileSpacing', 'compact');

nexttile;
plotDiscreteSeries(data.timeS, data.yawRateDegS, style.measuredColor);
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
u = data.uModelPwm;
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

figFilter = figure('Visible', figureVisibility(cfg), 'Color', 'w');
plotDiscreteSeries(data.timeS, data.yawRateDegS, style.measuredColor);
hold on;
plot(data.timeS, rad2deg(data.yawRateRadSFiltered), '-', 'Color', style.fitColor, 'LineWidth', 1.25);
applyAxesStyle(style);
xlabel('时间 (s)');
ylabel('角速度 (deg/s)');
title('阶段3 原始离散点与滤波后曲线对比');
legend({'原始离散点', '滤波后曲线'}, 'Location', 'best');
hold off;
stageResult.filter_comparison_figure = saveFigureBundle(figFilter, fullfile(stageFolder, 'stage3_filter_comparison'), cfg);

fig = figure('Visible', figureVisibility(cfg), 'Color', 'w', 'Name', '阶段3-alpha辨识');
tiledlayout(fig, 2, 1, 'Padding', 'compact', 'TileSpacing', 'compact');

nexttile;
plotDiscreteSeries(data.timeS, data.yawRateDegS, style.measuredColor);
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

u = data.uModelPwm;
r0 = data.yawRateRadSFiltered(1);
rNonlinear = nomoto_utils.simulateNonlinearNomoto(data.timeS, u, params.K, params.T, params.alpha, r0);
headingNonlinearDeg = cumtrapz(data.timeS, rad2deg(rNonlinear));
headingErrorDeg = data.headingRelDeg - headingNonlinearDeg;
validHeadingErrorDeg = headingErrorDeg(isfinite(headingErrorDeg));

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
if isempty(validHeadingErrorDeg)
    stageResult.heading_error_min_deg = NaN;
    stageResult.heading_error_max_deg = NaN;
else
    stageResult.heading_error_min_deg = min(validHeadingErrorDeg);
    stageResult.heading_error_max_deg = max(validHeadingErrorDeg);
end

figYawRate = figure('Visible', figureVisibility(cfg), 'Color', 'w', 'Name', '阶段4角速度验证');
plot(data.timeS, rad2deg(data.yawRateRadSFiltered), '-', 'Color', style.measuredColor, 'LineWidth', 1.1);
hold on;
plot(data.timeS, rad2deg(rNonlinear), '-', 'Color', style.fitColor, 'LineWidth', 1.25);
applyAxesStyle(style);
expandYAxis([rad2deg(data.yawRateRadSFiltered); rad2deg(rNonlinear)], 0.18);
xlabel('时间 (s)');
ylabel('角速度 (deg/s)');
title('阶段4 角速度验证');
legend({'滤波值', '非线性模型'}, 'Location', 'best');
hold off;

figHeading = figure('Visible', figureVisibility(cfg), 'Color', 'w', 'Name', '阶段4航向角验证');
plot(data.timeS, data.headingRelDeg, '-', 'Color', style.measuredColor, 'LineWidth', 1.0);
hold on;
plot(data.timeS, headingNonlinearDeg, '-', 'Color', style.fitColor, 'LineWidth', 1.25);
applyAxesStyle(style);
expandYAxis([data.headingRelDeg; headingNonlinearDeg], 0.18);
xlabel('时间 (s)');
ylabel('航向角 (deg)');
title('阶段4 航向角验证');
legend({'滤波值', '非线性模型'}, 'Location', 'best');
hold off;

stageResult.yaw_rate_figure = saveFigureBundle(figYawRate, fullfile(stageFolder, 'stage4_yaw_rate_validation'), cfg);
stageResult.heading_figure = saveFigureBundle(figHeading, fullfile(stageFolder, 'stage4_heading_validation'), cfg);
stageResult.figure = struct( ...
    'yaw_rate', stageResult.yaw_rate_figure, ...
    'heading', stageResult.heading_figure);

figErr = figure('Visible', figureVisibility(cfg), 'Color', 'w', 'Name', '阶段4航向角误差');
plot(data.timeS, headingErrorDeg, '-', 'Color', style.fitColor, 'LineWidth', 1.25);
hold on;
yline(0, '--', 'Color', style.referenceColor, 'LineWidth', 1.0);
applyAxesStyle(style);
xlabel('时间 (s)');
ylabel('航向角误差 (deg)');
title(sprintf('阶段4 航向角误差，RMSE = %.3f deg', stageResult.heading_rmse_deg));
legend({'实测-模型误差', '零误差参考线'}, 'Location', 'best');
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
    sprintf('u_trim 参数：%.12g', results.final_params.u_trim)
    ''
    '本次选中的文件：'
    };

if isfield(results.stage_results, 'stage1') && isfield(results.stage_results.stage1, 'turning_radius_m') ...
        && isfinite(results.stage_results.stage1.turning_radius_m)
    summaryLines{end + 1, 1} = sprintf('stage1 回转半径：%.6f m', results.stage_results.stage1.turning_radius_m); %#ok<AGROW>
    summaryLines{end + 1, 1} = sprintf('stage1 回转直径：%.6f m', results.stage_results.stage1.turning_diameter_m); %#ok<AGROW>
    summaryLines{end + 1, 1} = sprintf('stage1 尾段平均航速：%.6f m/s', results.stage_results.stage1.mean_speed_mps); %#ok<AGROW>
    summaryLines{end + 1, 1} = ''; %#ok<AGROW>
end

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
params.UTrim = cfg.UTrim;
params.SourceUTrim = 'config';
end

function params = initializeValidationParams(cfg)
params = struct();
params.K = cfg.OverrideK;
params.T = cfg.OverrideT;
params.alpha = cfg.OverrideAlpha;
params.UTrim = cfg.UTrim;
params.SourceK = 'validate_input';
params.SourceT = 'validate_input';
params.SourceAlpha = 'validate_input';
params.SourceUTrim = 'config';

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
out.u_trim = params.UTrim;
out.K_source = params.SourceK;
out.T_source = params.SourceT;
out.alpha_source = params.SourceAlpha;
out.u_trim_source = params.SourceUTrim;
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
style.measuredColor = [0.34, 0.16, 0.52];
style.inputColor = [0.30, 0.30, 0.30];
style.fitColor = [0.74, 0.21, 0.14];
style.referenceColor = [0.58, 0.65, 0.72];
style.headingColor = [0.00, 0.43, 0.32];
style.speedColor = [0.58, 0.42, 0.20];
style.pointColor = [0.34, 0.16, 0.52];
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

function expandYAxis(values, paddingRatio)
values = values(isfinite(values));
if isempty(values)
    return;
end

yMin = min(values);
yMax = max(values);
ySpan = yMax - yMin;
if ySpan <= eps
    yPad = max(1.0, 0.15 * max(abs([yMin, yMax])));
else
    yPad = paddingRatio * ySpan;
end
ylim([yMin - yPad, yMax + yPad]);
end

function h = plotDiscreteSeries(x, y, colorSpec)
h = scatter(x, y, 18, colorSpec, 'filled', ...
    'MarkerEdgeColor', [1, 1, 1], 'LineWidth', 0.45);
end

function saved = saveFigureBundle(fig, basePath, cfg)
saved = struct('eps', '', 'fig', '');
drawnow;

if cfg.SaveEpsFigures
    epsPath = [basePath '.eps'];
    exportgraphics(fig, epsPath, 'ContentType', 'vector');
    saved.eps = epsPath;
end

if isfield(cfg, 'SaveMatFigures') && cfg.SaveMatFigures
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

function value = meanFinite(values)
values = columnVector(values);
values = values(isfinite(values));
if isempty(values)
    value = NaN;
else
    value = mean(values);
end
end

function radiusM = estimateTurningRadius(speedMps, yawRateRadS)
if ~(isfinite(speedMps) && isfinite(yawRateRadS) && abs(yawRateRadS) > eps)
    radiusM = NaN;
else
    radiusM = abs(speedMps / yawRateRadS);
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
