%% PWM-速度实验日志分析脚本
% 功能说明：
% 1. 读取日志文件中的 time、pwm、speed 三个字段。
% 2. 绘制全程 time-pwm 点线图。
% 3. 绘制全程 time-speed 点线图。
% 4. 绘制分阶段 time-speed 子图。
% 5. 提取每个 PWM 阶段后段的平均速度，作为稳态速度。
% 6. 绘制稳态 pwm-speed 散点图，并在同一张图中完成最小二乘拟合。
%
% 日志格式示例：
% time=0,pwm=1000,speed=0.0
% time=1,pwm=1000,speed=1.1
% time=2,pwm=1000,speed=2.0
%
% 使用方式：
% - 直接修改下面“参数区”的文件路径。
% - 如果你的字段名不是 time / pwm / speed，也可以直接修改。
% - 然后运行本脚本即可。

clc;
clear;
close all;

%% ======================== 参数区（可直接修改） ========================

% 日志文件路径
logFile = 'sample_pwm_speed_log.txt';

% 日志中三个字段对应的名称
% 如果你的日志写成 timestamp=..., duty=..., velocity=...
% 那就把下面三个变量改成对应字段名即可。
timeKey  = 'time';
pwmKey   = 'pwm';
speedKey = 'speed';

% 稳态提取参数：取每个 PWM 阶段最后多少比例的数据做平均
steadyStateFraction = 0.30;

% 每个阶段最少用于稳态平均的点数
minSteadyPoints = 3;

% 最小二乘拟合阶数
% 1 = 直线拟合
% 2 = 二次曲线拟合
fitDegree = 1;

% 分阶段 time-speed 子图中是否使用相对时间
% true  -> 每一段都从 0 开始计时，更便于比较各段响应过程
% false -> 使用日志中的绝对时间
useRelativeTimeInSegmentPlots = true;

% 绘图样式
lineWidth = 1.2;
markerSize = 5;

%% ======================== 读取与解析日志 ========================

if ~isfile(logFile)
    error('找不到日志文件：%s', logFile);
end

[timeData, pwmData, speedData, rawLines] = parseLogFile(logFile, timeKey, pwmKey, speedKey);

if isempty(timeData)
    error('没有从日志中解析到有效数据，请检查日志格式和字段名设置。');
end

if numel(timeData) ~= numel(pwmData) || numel(timeData) ~= numel(speedData)
    error('解析后的 time、pwm、speed 数据长度不一致。');
end

% 为了避免日志顺序异常，先按时间排序
[timeData, sortIdx] = sort(timeData(:));
pwmData = pwmData(sortIdx);
speedData = speedData(sortIdx);

fprintf('成功读取文件：%s\n', logFile);
fprintf('总有效记录数：%d\n', numel(timeData));
fprintf('原始日志总行数：%d\n', numel(rawLines));

%% ======================== 按 PWM 变化分阶段 ========================

segments = splitIntoPwmSegments(timeData, pwmData, speedData);
numSegments = numel(segments);

fprintf('识别到 PWM 阶段数：%d\n', numSegments);

%% ======================== 图 1：全程 time-pwm ========================

figure('Name', 'Full Time-PWM', 'Color', 'w');
plot(timeData, pwmData, 'o-', 'LineWidth', lineWidth, 'MarkerSize', markerSize);
grid on;
xlabel('Time');
ylabel('PWM');
title('全程 PWM 随时间变化点线图');

%% ======================== 图 2：全程 time-speed ========================

figure('Name', 'Full Time-Speed', 'Color', 'w');
plot(timeData, speedData, 'o-', 'LineWidth', lineWidth, 'MarkerSize', markerSize);
grid on;
xlabel('Time');
ylabel('Speed');
title('全程速度随时间变化点线图');

%% ======================== 图 3：分阶段 time-speed 子图 ========================

figure('Name', 'Segmented Time-Speed', 'Color', 'w');
[numRows, numCols] = calcSubplotLayout(numSegments);

for i = 1:numSegments
    subplot(numRows, numCols, i);

    currentTime = segments(i).time;
    currentSpeed = segments(i).speed;
    currentPwm = segments(i).pwmValue;

    % 是否改为相对时间显示
    if useRelativeTimeInSegmentPlots
        plotTime = currentTime - currentTime(1);
        xLabelText = 'Relative Time';
    else
        plotTime = currentTime;
        xLabelText = 'Time';
    end

    plot(plotTime, currentSpeed, 'o-', 'LineWidth', lineWidth, 'MarkerSize', markerSize);
    grid on;
    xlabel(xLabelText);
    ylabel('Speed');
    title(sprintf('PWM = %.0f', currentPwm));
end

% 兼容较新和较旧版本的 MATLAB
if exist('sgtitle', 'file') == 2 || exist('sgtitle', 'builtin') == 5
    sgtitle('各 PWM 阶段的速度-时间子图');
else
    annotation('textbox', [0 0.96 1 0.03], ...
        'String', '各 PWM 阶段的速度-时间子图', ...
        'EdgeColor', 'none', ...
        'HorizontalAlignment', 'center', ...
        'FontWeight', 'bold');
end

%% ======================== 提取稳态速度 ========================

% 这里采用简单而实用的方法：
% 对每个 PWM 阶段，取该阶段最后一部分数据求平均，作为稳态速度。
[steadyPwm, steadySpeed, steadyInfo] = computeSteadyStateByTailMean( ...
    segments, steadyStateFraction, minSteadyPoints);

fprintf('\n稳态提取结果：\n');
for i = 1:numel(steadyPwm)
    fprintf('阶段 %2d: PWM = %6.1f, 稳态速度均值 = %8.3f, 使用点数 = %d\n', ...
        i, steadyPwm(i), steadySpeed(i), steadyInfo(i).numPointsUsed);
end

%% ======================== 图 4：稳态 pwm-speed + 最小二乘拟合 ========================

figure('Name', 'Steady PWM-Speed with Fit', 'Color', 'w');
hold on;
grid on;

% 先画稳态散点
scatter(steadyPwm, steadySpeed, 60, 'filled', 'DisplayName', '稳态散点');

% 再进行最小二乘拟合
% polyfit 本质上就是基于最小二乘法进行多项式拟合
if numel(steadyPwm) >= fitDegree + 1
    fitCoeff = polyfit(steadyPwm, steadySpeed, fitDegree);
    xFit = linspace(min(steadyPwm), max(steadyPwm), 300);
    yFit = polyval(fitCoeff, xFit);

    plot(xFit, yFit, 'r-', 'LineWidth', 1.8, ...
        'DisplayName', sprintf('%d 阶最小二乘拟合', fitDegree));

    % 计算 R^2，方便判断拟合效果
    yPred = polyval(fitCoeff, steadyPwm);
    rSquared = computeRSquared(steadySpeed, yPred);

    % 生成拟合公式字符串
    fitText = polynomialToString(fitCoeff);

    title({ ...
        '稳态 PWM-Speed 特性曲线'; ...
        sprintf('拟合公式: %s', fitText); ...
        sprintf('R^2 = %.4f', rSquared) ...
        });
else
    warning('稳态点数量不足，无法进行 %d 阶拟合。', fitDegree);
    title('稳态 PWM-Speed 特性曲线（稳态点不足，未进行拟合）');
end

xlabel('PWM');
ylabel('Steady Speed');
legend('Location', 'best');
hold off;

%% ======================== 命令行输出拟合结果 ========================

if exist('fitCoeff', 'var')
    fprintf('\n最小二乘拟合结果（多项式系数）：\n');
    disp(fitCoeff);
end

fprintf('\n分析完成。\n');

%% ======================== 本地函数区 ========================

function [timeData, pwmData, speedData, rawLines] = parseLogFile(logFile, timeKey, pwmKey, speedKey)
% 读取日志文件，并从每一行中提取 time / pwm / speed 三个数值字段。

    fileText = fileread(logFile);
    rawLines = splitlines(string(fileText));

    timeData = [];
    pwmData = [];
    speedData = [];

    for lineIndex = 1:numel(rawLines)
        oneLine = strtrim(rawLines(lineIndex));

        % 跳过空行
        if strlength(oneLine) == 0
            continue;
        end

        timeValue = extractNumericValue(oneLine, timeKey);
        pwmValue = extractNumericValue(oneLine, pwmKey);
        speedValue = extractNumericValue(oneLine, speedKey);

        % 只有三个字段都成功提取时，才算有效数据
        if ~(isnan(timeValue) || isnan(pwmValue) || isnan(speedValue))
            timeData(end + 1, 1) = timeValue; %#ok<AGROW>
            pwmData(end + 1, 1) = pwmValue; %#ok<AGROW>
            speedData(end + 1, 1) = speedValue; %#ok<AGROW>
        end
    end
end

function value = extractNumericValue(oneLine, keyName)
% 从一行日志里提取 key=value 中的数值。
% 支持整数、小数和科学计数法。

    pattern = ['(?:^|,)\s*', regexptranslate('escape', keyName), ...
        '\s*=\s*([+-]?\d*\.?\d+(?:[eE][+-]?\d+)?)'];

    token = regexp(char(oneLine), pattern, 'tokens', 'once');

    if isempty(token)
        value = NaN;
    else
        value = str2double(token{1});
    end
end

function segments = splitIntoPwmSegments(timeData, pwmData, speedData)
% 按“PWM 连续不变”的原则把整段数据切分为多个阶段。

    if isempty(pwmData)
        segments = struct('time', {}, 'pwm', {}, 'speed', {}, 'pwmValue', {});
        return;
    end

    changeIndex = [1; find(diff(pwmData) ~= 0) + 1; numel(pwmData) + 1];
    segmentCount = numel(changeIndex) - 1;

    segments = repmat(struct('time', [], 'pwm', [], 'speed', [], 'pwmValue', []), segmentCount, 1);

    for i = 1:segmentCount
        startIdx = changeIndex(i);
        endIdx = changeIndex(i + 1) - 1;

        segments(i).time = timeData(startIdx:endIdx);
        segments(i).pwm = pwmData(startIdx:endIdx);
        segments(i).speed = speedData(startIdx:endIdx);
        segments(i).pwmValue = pwmData(startIdx);
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

function rSquared = computeRSquared(yTrue, yPred)
% 计算决定系数 R^2。

    ssRes = sum((yTrue - yPred).^2);
    ssTot = sum((yTrue - mean(yTrue)).^2);

    if ssTot == 0
        rSquared = 1;
    else
        rSquared = 1 - ssRes / ssTot;
    end
end

function textStr = polynomialToString(coeff)
% 将 polyfit 的多项式系数转换为可读公式。
% 例如 [0.12, -118] 会转成 0.12*x - 118

    degree = numel(coeff) - 1;
    parts = strings(1, numel(coeff));

    for i = 1:numel(coeff)
        currentCoeff = coeff(i);
        currentPower = degree - (i - 1);

        if currentPower > 1
            parts(i) = sprintf('%.6g*x^%d', currentCoeff, currentPower);
        elseif currentPower == 1
            parts(i) = sprintf('%.6g*x', currentCoeff);
        else
            parts(i) = sprintf('%.6g', currentCoeff);
        end
    end

    textStr = strjoin(parts, ' + ');
    textStr = strrep(textStr, '+ -', '- ');
end
