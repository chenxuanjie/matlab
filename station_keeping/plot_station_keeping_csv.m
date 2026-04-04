function results = plot_station_keeping_csv(experimentRoot, opts)
% ======================== 输入配置区（可直接修改） ========================
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
% 电机中位 PWM。按 left/right PWM 是否偏离该值，判断电机是否开启
neutralPwm = 1500;
%
% 判定电机开启的 PWM 容差
pwmActiveTolerance = 1e-6;
%
% 距离/状态对比图尺寸（像素）
distanceFigureWidth = 1280;
distanceFigureHeight = 820;
%
% 轨迹图尺寸（像素）
trajectoryFigureWidth = 920;
trajectoryFigureHeight = 820;
%
% 回收细节图尺寸（像素）
recoveryFigureWidth = 1280;
recoveryFigureHeight = 980;
%
% 说明：
% 1. 第一个输入 experimentRoot 可以是 CSV 文件路径，也可以是文件夹路径
% 2. 如果传入文件夹，脚本会递归选择最新的 station_keeping_run*.csv
% 3. 如果留空，则默认在 matlab 根目录下递归搜索最新 CSV
% 4. 时间轴统一从 0 s 开始

if nargin < 1
    experimentRoot = '';
end
if nargin < 2 || isempty(opts)
    opts = struct();
    opts.ShowFigures = showFigures;
    opts.SaveEpsFigures = saveEpsFigures;
    opts.NeutralPwm = neutralPwm;
    opts.PwmActiveTolerance = pwmActiveTolerance;
    opts.DistanceFigureWidth = distanceFigureWidth;
    opts.DistanceFigureHeight = distanceFigureHeight;
    opts.TrajectoryFigureWidth = trajectoryFigureWidth;
    opts.TrajectoryFigureHeight = trajectoryFigureHeight;
    opts.RecoveryFigureWidth = recoveryFigureWidth;
    opts.RecoveryFigureHeight = recoveryFigureHeight;
    if ~isempty(outputRoot)
        opts.OutputRoot = outputRoot;
    end
end

scriptDir = fileparts(mfilename('fullpath'));
cfg = buildConfig(scriptDir, experimentRoot, opts);
selectedCsv = resolveCsvFile(cfg);

[~, csvBaseName] = fileparts(selectedCsv);
cfg.RunOutputRoot = fullfile(cfg.OutputRoot, [csvBaseName '_' cfg.RunStamp]);
ensureFolder(cfg.OutputRoot);
ensureFolder(cfg.RunOutputRoot);

fprintf('===== Station Keeping CSV 绘图 =====\n');
fprintf('本次选中的 CSV 文件：\n  %s\n', selectedCsv);

data = readStationKeepingData(selectedCsv, cfg);

distanceStateFiles = plotDistanceAndMotorStateFigure(data, cfg);
trajectoryFiles = plotTrajectoryFigure(data, cfg);
recoveryEpisodeFiles = plotRecoveryEpisodeFigures(data, cfg);

results = struct();
results.generated_at = char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'));
results.selected_file = selectedCsv;
results.output_root = cfg.RunOutputRoot;
results.summary = buildSummary(data);
results.figure_files = struct();
results.figure_files.distance_state = distanceStateFiles;
results.figure_files.trajectory = trajectoryFiles;
results.figure_files.recovery_episodes = recoveryEpisodeFiles;

save(fullfile(cfg.RunOutputRoot, 'station_keeping_results.mat'), 'results');

fprintf('\n结果摘要：\n');
fprintf('  数据时长: %.3f s\n', results.summary.duration_s);
fprintf('  采样点数: %d\n', results.summary.sample_count);
fprintf('  R_in: %.3f m\n', results.summary.R_in_m);
fprintf('  R_out: %.3f m\n', results.summary.R_out_m);
fprintf('  最小距离: %.3f m\n', results.summary.distance_min_m);
fprintf('  最大距离: %.3f m\n', results.summary.distance_max_m);
fprintf('  电机开启占比: %.2f %%\n', results.summary.motor_on_ratio * 100.0);
fprintf('  检测到的回收事件数: %d\n', results.summary.recovery_episode_count);
fprintf('  输出目录: %s\n', cfg.RunOutputRoot);
end

function cfg = buildConfig(scriptDir, experimentRoot, opts)
cfg = struct();
cfg.ScriptDir = scriptDir;
cfg.ProjectRoot = fileparts(scriptDir);
cfg.RunStamp = char(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));
cfg.OutputRoot = getOption(opts, 'OutputRoot', fullfile(scriptDir, 'results'));
cfg.OutputRoot = char(string(cfg.OutputRoot));
cfg.ShowFigures = logical(getOption(opts, 'ShowFigures', true));
cfg.SaveEpsFigures = logical(getOption(opts, 'SaveEpsFigures', false));
cfg.DisplayFontName = 'SimSun';
cfg.NeutralPwm = getOption(opts, 'NeutralPwm', 1500);
cfg.PwmActiveTolerance = getOption(opts, 'PwmActiveTolerance', 1e-6);
cfg.DistanceFigureWidth = max(640, round(getOption(opts, 'DistanceFigureWidth', 1280)));
cfg.DistanceFigureHeight = max(420, round(getOption(opts, 'DistanceFigureHeight', 820)));
cfg.TrajectoryFigureWidth = max(640, round(getOption(opts, 'TrajectoryFigureWidth', 920)));
cfg.TrajectoryFigureHeight = max(420, round(getOption(opts, 'TrajectoryFigureHeight', 820)));
cfg.RecoveryFigureWidth = max(720, round(getOption(opts, 'RecoveryFigureWidth', 1280)));
cfg.RecoveryFigureHeight = max(560, round(getOption(opts, 'RecoveryFigureHeight', 980)));
cfg.SearchPattern = 'station_keeping_run*.csv';

if nargin < 2 || isempty(experimentRoot)
    cfg.UseExplicitFile = false;
    cfg.SearchRoot = cfg.ProjectRoot;
    return;
end

inputPath = char(string(experimentRoot));
if isfile(inputPath)
    cfg.UseExplicitFile = true;
    cfg.ExplicitFile = inputPath;
    cfg.SearchRoot = fileparts(inputPath);
elseif isfolder(inputPath)
    cfg.UseExplicitFile = false;
    cfg.SearchRoot = inputPath;
else
    error('输入路径不存在：%s', inputPath);
end
end

function selectedCsv = resolveCsvFile(cfg)
if isfield(cfg, 'UseExplicitFile') && cfg.UseExplicitFile
    selectedCsv = cfg.ExplicitFile;
    return;
end

listing = dir(fullfile(cfg.SearchRoot, '**', cfg.SearchPattern));
if isempty(listing)
    error(['未找到 station keeping CSV 文件。' ...
        '请传入 CSV 文件路径，或传入包含 station_keeping_run*.csv 的文件夹。']);
end

[~, order] = sort([listing.datenum], 'descend');
listing = listing(order);
selectedCsv = fullfile(listing(1).folder, listing(1).name);
end

function data = readStationKeepingData(filePath, cfg)
tbl = readtable(filePath, 'TextType', 'string');

requiredColumns = {
    'elapsed_time_s'
    'target_x_m'
    'target_y_m'
    'current_x_m'
    'current_y_m'
    'distance_to_target_m'
    'desired_heading_deg'
    'current_heading_deg'
    'left_pwm'
    'right_pwm'
    'loiter_radius_m'
    'reenter_radius_m'
    };

missingColumns = requiredColumns(~ismember(requiredColumns, tbl.Properties.VariableNames));
if ~isempty(missingColumns)
    error('CSV 缺少必要列：%s', strjoin(missingColumns, ', '));
end

timeS = tbl.elapsed_time_s;
distanceM = tbl.distance_to_target_m;
desiredHeadingDeg = tbl.desired_heading_deg;
currentHeadingDeg = tbl.current_heading_deg;
currentXM = tbl.current_x_m;
currentYM = tbl.current_y_m;
leftPwm = tbl.left_pwm;
rightPwm = tbl.right_pwm;

if isempty(timeS)
    error('CSV 为空，无法绘图：%s', filePath);
end

timeS = double(timeS) - double(timeS(1));
distanceM = double(distanceM);
desiredHeadingDeg = double(desiredHeadingDeg);
currentHeadingDeg = double(currentHeadingDeg);
currentXM = double(currentXM);
currentYM = double(currentYM);
leftPwm = double(leftPwm);
rightPwm = double(rightPwm);

[rOutM, rOutChanged] = extractRepresentativeScalar(tbl.loiter_radius_m, 'R_out');
[rInM, rInChanged] = extractRepresentativeScalar(tbl.reenter_radius_m, 'R_in');
[targetXM, targetXChanged] = extractRepresentativeScalar(tbl.target_x_m, 'target_x_m');
[targetYM, targetYChanged] = extractRepresentativeScalar(tbl.target_y_m, 'target_y_m');

if rOutChanged
    warning('检测到 loiter_radius_m 在 CSV 中发生变化，已使用首个有效值作为 R_out。');
end
if rInChanged
    warning('检测到 reenter_radius_m 在 CSV 中发生变化，已使用首个有效值作为 R_in。');
end
if targetXChanged || targetYChanged
    warning('检测到目标点坐标在 CSV 中发生变化，轨迹图将使用首个有效目标点。');
end
if any(diff(timeS) < 0)
    warning('检测到 elapsed_time_s 非单调递增，图中仍按原始顺序绘制。');
end

leftMotorOn = isfinite(leftPwm) & abs(leftPwm - cfg.NeutralPwm) > cfg.PwmActiveTolerance;
rightMotorOn = isfinite(rightPwm) & abs(rightPwm - cfg.NeutralPwm) > cfg.PwmActiveTolerance;
motorOn = double(leftMotorOn | rightMotorOn);

data = struct();
data.FilePath = filePath;
data.FileName = string(filePath);
data.Table = tbl;
data.TimeS = timeS;
data.DistanceM = distanceM;
data.DesiredHeadingDeg = desiredHeadingDeg;
data.CurrentHeadingDeg = currentHeadingDeg;
data.CurrentXM = currentXM;
data.CurrentYM = currentYM;
data.TargetXM = targetXM;
data.TargetYM = targetYM;
data.LeftPwm = leftPwm;
data.RightPwm = rightPwm;
data.YawPwmDelta = getOptionalNumericColumn(tbl, 'yaw_pwm_delta', NaN(height(tbl), 1));
data.Recovering = getOptionalNumericColumn(tbl, 'recovering', NaN(height(tbl), 1));
data.HeadingOnly = getOptionalNumericColumn(tbl, 'heading_only', NaN(height(tbl), 1));
data.State = getOptionalStringColumn(tbl, 'state', strings(height(tbl), 1));
data.MotorOn = motorOn;
data.RInM = rInM;
data.ROutM = rOutM;
data.RecoveryEpisodes = detectRecoveryEpisodes(data);
end

function [value, changed] = extractRepresentativeScalar(values, valueName)
values = double(values);
validValues = values(isfinite(values));
if isempty(validValues)
    error('列 %s 不包含有效数值。', valueName);
end

value = validValues(1);
changed = any(abs(validValues - value) > 1e-9);
end

function values = getOptionalNumericColumn(tbl, columnName, defaultValue)
if ismember(columnName, tbl.Properties.VariableNames)
    values = double(tbl.(columnName));
else
    values = defaultValue;
end
end

function values = getOptionalStringColumn(tbl, columnName, defaultValue)
if ismember(columnName, tbl.Properties.VariableNames)
    values = string(tbl.(columnName));
else
    values = defaultValue;
end
end

function files = plotDistanceAndMotorStateFigure(data, cfg)
style = plotStyle();
fig = figure('Color', 'w', ...
    'Position', [120, 120, cfg.DistanceFigureWidth, cfg.DistanceFigureHeight], ...
    'Name', 'station_keeping_distance_motor_state');

t = tiledlayout(fig, 2, 1, 'TileSpacing', 'compact', 'Padding', 'compact');

ax1 = nexttile(t, 1);
hold(ax1, 'on');
plot(ax1, data.TimeS, data.DistanceM, ...
    'LineWidth', style.MainLineWidth, ...
    'Color', style.DistanceColor, ...
    'DisplayName', '距离目标点');
yline(ax1, data.RInM, '--', ...
    'LineWidth', style.ReferenceLineWidth, ...
    'Color', style.InnerRadiusColor, ...
    'DisplayName', 'R_{in}');
yline(ax1, data.ROutM, '--', ...
    'LineWidth', style.ReferenceLineWidth, ...
    'Color', style.OuterRadiusColor, ...
    'DisplayName', 'R_{out}');
grid(ax1, 'on');
box(ax1, 'on');
ylabel(ax1, '距离 (m)');
applyAxesFont(ax1, cfg);
legend(ax1, 'Location', 'best');

ax2 = nexttile(t, 2);
hold(ax2, 'on');
stairs(ax2, data.TimeS, data.MotorOn, ...
    'LineWidth', style.StateLineWidth, ...
    'Color', style.MotorColor, ...
    'DisplayName', '电机状态');
grid(ax2, 'on');
box(ax2, 'on');
xlabel(ax2, '时间 (s)');
ylabel(ax2, '电机状态');
applyAxesFont(ax2, cfg);
ylim(ax2, [-0.1, 1.1]);
yticks(ax2, [0, 1]);
yticklabels(ax2, {'0', '1'});
[timeMin, timeMax] = computeAxisLimits(data.TimeS);
xlim(ax2, [timeMin, timeMax]);

linkaxes([ax1, ax2], 'x');
files = saveFigure(fig, cfg.RunOutputRoot, 'distance_motor_state', cfg);
end

function files = plotTrajectoryFigure(data, cfg)
style = plotStyle();
fig = figure('Color', 'w', ...
    'Position', [180, 150, cfg.TrajectoryFigureWidth, cfg.TrajectoryFigureHeight], ...
    'Name', 'station_keeping_trajectory');
ax = axes(fig);
hold(ax, 'on');

plot(ax, data.CurrentXM, data.CurrentYM, ...
    'LineWidth', style.MainLineWidth, ...
    'Color', style.TrajectoryColor, ...
    'DisplayName', '无人艇轨迹');

startValid = find(isfinite(data.CurrentXM) & isfinite(data.CurrentYM), 1, 'first');
endValid = find(isfinite(data.CurrentXM) & isfinite(data.CurrentYM), 1, 'last');
if ~isempty(startValid)
    plot(ax, data.CurrentXM(startValid), data.CurrentYM(startValid), 'o', ...
        'MarkerSize', 7, ...
        'MarkerFaceColor', style.StartColor, ...
        'MarkerEdgeColor', style.StartColor, ...
        'DisplayName', '起点');
end
if ~isempty(endValid)
    plot(ax, data.CurrentXM(endValid), data.CurrentYM(endValid), 's', ...
        'MarkerSize', 7, ...
        'MarkerFaceColor', style.EndColor, ...
        'MarkerEdgeColor', style.EndColor, ...
        'DisplayName', '终点');
end

plot(ax, data.TargetXM, data.TargetYM, 'p', ...
    'MarkerSize', 12, ...
    'MarkerFaceColor', style.TargetColor, ...
    'MarkerEdgeColor', style.TargetColor, ...
    'DisplayName', '目标点');
plotCircle(ax, data.TargetXM, data.TargetYM, data.RInM, style.InnerRadiusColor, '--', 'R_{in}');
plotCircle(ax, data.TargetXM, data.TargetYM, data.ROutM, style.OuterRadiusColor, '--', 'R_{out}');

grid(ax, 'on');
box(ax, 'on');
axis(ax, 'equal');
xlabel(ax, '局部横坐标 (m)');
ylabel(ax, '局部纵坐标 (m)');
applyAxesFont(ax, cfg);
legend(ax, 'Location', 'best');

files = saveFigure(fig, cfg.RunOutputRoot, 'trajectory', cfg);
end

function files = plotRecoveryEpisodeFigures(data, cfg)
episodes = data.RecoveryEpisodes;
files = struct('episode_index', {}, 'start_time_s', {}, 'end_time_s', {}, ...
    'duration_s', {}, 'reentered_R_in', {}, 'png', {});

if isempty(episodes)
    warning(['未检测到满足“distance >= R_out 且电机由 0 跳到 1”条件的回收事件，' ...
        '已跳过回收细节图。']);
    return;
end

for i = 1:numel(episodes)
    savedFiles = plotSingleRecoveryEpisodeFigure(data, episodes(i), i, cfg);
    files(i).episode_index = i;
    files(i).start_time_s = episodes(i).startTimeS;
    files(i).end_time_s = episodes(i).endTimeS;
    files(i).duration_s = episodes(i).endTimeS - episodes(i).startTimeS;
    files(i).reentered_R_in = episodes(i).reenteredRIn;
    files(i).png = savedFiles.png;
    if isfield(savedFiles, 'eps')
        files(i).eps = savedFiles.eps;
    end
end
end

function files = plotSingleRecoveryEpisodeFigure(data, episode, episodeIndex, cfg)
style = plotStyle();
idx = episode.startIndex:episode.endIndex;
tLocal = data.TimeS(idx) - data.TimeS(episode.startIndex);

desiredHeading = unwrapDegrees(data.DesiredHeadingDeg(idx));
currentHeading = unwrapDegrees(data.CurrentHeadingDeg(idx));
diffPwm = data.RightPwm(idx) - data.LeftPwm(idx);
yawPwmDelta = data.YawPwmDelta(idx);

fig = figure('Color', 'w', ...
    'Position', [140, 120, cfg.RecoveryFigureWidth, cfg.RecoveryFigureHeight], ...
    'Name', sprintf('station_keeping_recovery_episode_%02d', episodeIndex));

t = tiledlayout(fig, 3, 1, 'TileSpacing', 'compact', 'Padding', 'compact');

ax1 = nexttile(t, 1);
hold(ax1, 'on');
plot(ax1, tLocal, data.DistanceM(idx), ...
    'LineWidth', style.MainLineWidth, ...
    'Color', style.DistanceColor, ...
    'DisplayName', '距离目标点');
yline(ax1, data.RInM, '--', ...
    'LineWidth', style.ReferenceLineWidth, ...
    'Color', style.InnerRadiusColor, ...
    'DisplayName', 'R_{in}');
yline(ax1, data.ROutM, '--', ...
    'LineWidth', style.ReferenceLineWidth, ...
    'Color', style.OuterRadiusColor, ...
    'DisplayName', 'R_{out}');
grid(ax1, 'on');
box(ax1, 'on');
ylabel(ax1, '距离 (m)');
applyAxesFont(ax1, cfg);
legend(ax1, 'Location', 'best');

ax2 = nexttile(t, 2);
hold(ax2, 'on');
plot(ax2, tLocal, desiredHeading, ...
    'LineWidth', style.MainLineWidth, ...
    'Color', style.DesiredHeadingColor, ...
    'DisplayName', '目标航向角');
plot(ax2, tLocal, currentHeading, ...
    'LineWidth', style.MainLineWidth, ...
    'Color', style.CurrentHeadingColor, ...
    'DisplayName', '实际航向角');
grid(ax2, 'on');
box(ax2, 'on');
ylabel(ax2, '航向角 (°)');
applyAxesFont(ax2, cfg);
legend(ax2, 'Location', 'best');

ax3 = nexttile(t, 3);
hold(ax3, 'on');
plot(ax3, tLocal, diffPwm, ...
    'LineWidth', style.MainLineWidth, ...
    'Color', style.DiffPwmColor, ...
    'DisplayName', '\DeltaPWM = right\_pwm - left\_pwm');
if any(isfinite(yawPwmDelta))
    plot(ax3, tLocal, yawPwmDelta, '--', ...
        'LineWidth', style.ReferenceLineWidth, ...
        'Color', style.YawDeltaColor, ...
        'DisplayName', 'yaw\_pwm\_delta');
end
yline(ax3, 0, '--', ...
    'LineWidth', 1.0, ...
    'Color', [0.45, 0.45, 0.45], ...
    'DisplayName', '零差速');
grid(ax3, 'on');
box(ax3, 'on');
xlabel(ax3, '相对时间 (s)');
ylabel(ax3, 'PWM 差值 (PWM)');
applyAxesFont(ax3, cfg);
legend(ax3, 'Location', 'best');

[timeMin, timeMax] = computeAxisLimits(tLocal);
xlim(ax1, [timeMin, timeMax]);
xlim(ax2, [timeMin, timeMax]);
xlim(ax3, [timeMin, timeMax]);


files = saveFigure(fig, cfg.RunOutputRoot, ...
    sprintf('recovery_episode_%02d_detail', episodeIndex), cfg);
end

function episodes = detectRecoveryEpisodes(data)
motorOn = data.MotorOn > 0.5;
startCandidates = find(diff([0; motorOn(:)]) == 1);
episodes = struct('startIndex', {}, 'endIndex', {}, 'startTimeS', {}, ...
    'endTimeS', {}, 'reenteredRIn', {});

writeIdx = 0;
for i = 1:numel(startCandidates)
    startIndex = startCandidates(i);
    startDistance = data.DistanceM(startIndex);
    if ~isfinite(startDistance) || startDistance < data.ROutM
        continue;
    end

    reenterCandidates = find(isfinite(data.DistanceM(startIndex:end)) & ...
        data.DistanceM(startIndex:end) <= data.RInM, 1, 'first');
    motorOffCandidates = find(diff([motorOn(startIndex:end); 0]) == -1, 1, 'first');

    if ~isempty(reenterCandidates)
        endIndex = startIndex + reenterCandidates - 1;
        reenteredRIn = true;
    elseif ~isempty(motorOffCandidates)
        endIndex = startIndex + motorOffCandidates - 1;
        reenteredRIn = false;
    else
        endIndex = numel(data.TimeS);
        reenteredRIn = false;
    end

    if endIndex <= startIndex
        endIndex = min(numel(data.TimeS), startIndex + 1);
    end

    writeIdx = writeIdx + 1;
    episodes(writeIdx).startIndex = startIndex;
    episodes(writeIdx).endIndex = endIndex;
    episodes(writeIdx).startTimeS = data.TimeS(startIndex);
    episodes(writeIdx).endTimeS = data.TimeS(endIndex);
    episodes(writeIdx).reenteredRIn = reenteredRIn;
end
end

function plotCircle(ax, centerX, centerY, radius, colorSpec, lineStyle, displayName)
theta = linspace(0, 2 * pi, 361);
x = centerX + radius * cos(theta);
y = centerY + radius * sin(theta);
plot(ax, x, y, ...
    'LineStyle', lineStyle, ...
    'LineWidth', 1.4, ...
    'Color', colorSpec, ...
    'DisplayName', displayName);
end

function summary = buildSummary(data)
validDistance = data.DistanceM(isfinite(data.DistanceM));
if isempty(validDistance)
    error('distance_to_target_m 不包含有效数值，无法生成摘要。');
end

summary = struct();
summary.duration_s = data.TimeS(end) - data.TimeS(1);
summary.sample_count = numel(data.TimeS);
summary.R_in_m = data.RInM;
summary.R_out_m = data.ROutM;
summary.distance_min_m = min(validDistance);
summary.distance_max_m = max(validDistance);
summary.distance_mean_m = mean(validDistance);
summary.motor_on_ratio = mean(data.MotorOn > 0);
summary.recovery_episode_count = numel(data.RecoveryEpisodes);
end

function [axisMin, axisMax] = computeAxisLimits(values)
axisMin = min(values);
axisMax = max(values);
if ~isfinite(axisMin) || ~isfinite(axisMax)
    axisMin = 0;
    axisMax = 1;
elseif axisMax <= axisMin
    axisMax = axisMin + 1;
end
end

function applyAxesFont(ax, cfg)
if nargin < 1 || isempty(ax)
    ax = gca;
end

fontName = 'SimSun';
if nargin >= 2 && isstruct(cfg) && isfield(cfg, 'DisplayFontName') && ~isempty(cfg.DisplayFontName)
    fontName = cfg.DisplayFontName;
end

set(ax, 'FontName', fontName);
if isgraphics(ax.XLabel)
    set(ax.XLabel, 'FontName', fontName);
end
if isgraphics(ax.YLabel)
    set(ax.YLabel, 'FontName', fontName);
end
if isgraphics(ax.ZLabel)
    set(ax.ZLabel, 'FontName', fontName);
end
end

function valuesOut = unwrapDegrees(valuesIn)
valuesOut = double(valuesIn(:));
finiteMask = isfinite(valuesOut);
if ~any(finiteMask)
    return;
end

edges = diff([false; finiteMask; false]);
segmentStarts = find(edges == 1);
segmentEnds = find(edges == -1) - 1;

for i = 1:numel(segmentStarts)
    idx = segmentStarts(i):segmentEnds(i);
    valuesOut(idx) = rad2deg(unwrap(deg2rad(valuesOut(idx))));
end
end

function style = plotStyle()
style = struct();
style.DistanceColor = [0.10, 0.33, 0.63];
style.MotorColor = [0.78, 0.20, 0.18];
style.TrajectoryColor = [0.14, 0.58, 0.41];
style.TargetColor = [0.93, 0.60, 0.12];
style.InnerRadiusColor = [0.85, 0.33, 0.10];
style.OuterRadiusColor = [0.49, 0.18, 0.56];
style.StartColor = [0.20, 0.20, 0.20];
style.EndColor = [0.00, 0.45, 0.74];
style.DesiredHeadingColor = [0.20, 0.48, 0.72];
style.CurrentHeadingColor = [0.84, 0.37, 0.00];
style.DiffPwmColor = [0.62, 0.16, 0.40];
style.YawDeltaColor = [0.25, 0.25, 0.25];
style.MainLineWidth = 1.8;
style.StateLineWidth = 1.8;
style.ReferenceLineWidth = 1.4;
end

function files = saveFigure(fig, outputFolder, fileTag, cfg)
pngPath = fullfile(outputFolder, [fileTag '.png']);
exportgraphics(fig, pngPath, 'Resolution', 300);

files = struct();
files.png = pngPath;

if cfg.SaveEpsFigures
    epsPath = fullfile(outputFolder, [fileTag '.eps']);
    exportgraphics(fig, epsPath, 'ContentType', 'vector');
    files.eps = epsPath;
end

if ~cfg.ShowFigures
    close(fig);
end
end

function ensureFolder(folderPath)
if isempty(folderPath)
    return;
end
if ~isfolder(folderPath)
    mkdir(folderPath);
end
end

function value = getOption(opts, fieldName, defaultValue)
if isstruct(opts) && isfield(opts, fieldName) && ~isempty(opts.(fieldName))
    value = opts.(fieldName);
else
    value = defaultValue;
end
end
