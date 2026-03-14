%% 非线性 Nomoto 模型轨迹仿真脚本
% 模型形式：
%   T * dr/dt + r + alpha * r^3 = K * delta(t)
%
% 状态含义：
%   r   : 艏摇角速度
%   psi : 航向角，满足 dpsi/dt = r
%
% 平面运动假设：
%   U 为恒定前进速度
%   dx/dt = U * cos(psi)
%   dy/dt = U * sin(psi)
%
% 这个脚本适合在你已经识别出 K、T、alpha 之后，
% 直接输入不同舵角形式，查看模型在平面中的运动趋势。
%
% 功能包括：
% 1. 绘制舵角输入时序
% 2. 绘制艏摇角速度响应
% 3. 绘制航向角变化
% 4. 绘制二维平面轨迹
% 5. 可选地播放简单动画
%
% 说明：
% - 默认初始速度为 1 m/s，可直接在参数区修改。
% - 舵角支持常值和时变两种输入方式。
% - 当前默认舵角为常值 30 度。

clc;
clear;
close all;

%% ======================== 模型参数区 ========================

% 请将这里替换为你识别得到的参数
K = -0.9600004;
T = 0.052562502;
alpha = -1.6382E-05;

%% ======================== 仿真参数区 ========================

% 仿真总时长（秒）
totalTime = 120;

% 时间步长（秒）
dt = 0.1;

% 恒定前进速度（m/s）
forwardSpeed = 1;

% 初始位置（米）
x0 = 0;
y0 = 0;

% 初始航向角（度）
psi0Deg = 0;

% 初始艏摇角速度（deg/s）
r0DegPerSec = 0;

% 图形显示选项
showDirectionArrow = true;
enableAnimation = false;
animationStep = 10;
boatLengthForAnimation = 0.6;

% 轨迹图坐标轴范围会根据轨迹自动居中并自动留白，
% 不需要手动调节额外参数。

%% ======================== 舵角输入配置区 ========================

% 舵角输入模式：
% 'constant'  : 常值舵角
% 'step'      : 阶跃舵角
% 'sin'       : 正弦舵角
% 'piecewise' : 分段常值舵角
% 'custom'    : 自定义时变舵角（线性插值）
rudderMode = 'step';

% 1) constant 模式：整个仿真过程舵角保持不变
constantDeltaDeg = 30;

% 2) step 模式：stepStartTime 之前为 initialStepDeltaDeg，之后变为 finalStepDeltaDeg
stepStartTime = 10;
initialStepDeltaDeg = 0;
finalStepDeltaDeg = 30;

% 3) sin 模式：
% delta(t) = sinBiasDeg + sinAmplitudeDeg * sin(2*pi*sinFrequencyHz*t)
sinBiasDeg = 0;
sinAmplitudeDeg = 30;
sinFrequencyHz = 0.02;

% 4) piecewise 模式：每个时间区间内保持常值
piecewiseTimeBreaks = [0, 20, 40, 60, 80];
piecewiseDeltaDeg = [0, 10, 20, -15, 0];

% 5) custom 模式：按给定时间点和舵角点进行线性插值
customRudderTime = [0, 10, 20, 40, 60, 90, 120];
customRudderDeg = [0, 5, 15, 30, 10, -10, 0];

%% ======================== 显示单位设置 ========================

angleDisplayUnit = 'deg';
yawRateDisplayUnit = 'deg/s';

%% ======================== 输入合法性检查 ========================

if totalTime <= 0
    error('totalTime 必须大于 0。');
end

if dt <= 0
    error('dt 必须大于 0。');
end

if T <= 0
    error('T 必须大于 0。');
end

%% ======================== 生成时间轴与舵角输入 ========================

time = (0:dt:totalTime).';

deltaDeg = generateRudderInput(time, rudderMode, ...
    constantDeltaDeg, ...
    stepStartTime, initialStepDeltaDeg, finalStepDeltaDeg, ...
    sinBiasDeg, sinAmplitudeDeg, sinFrequencyHz, ...
    piecewiseTimeBreaks, piecewiseDeltaDeg, ...
    customRudderTime, customRudderDeg);

deltaRad = nomoto_utils.angleToRad(deltaDeg, 'deg');
psi0Rad = nomoto_utils.angleToRad(psi0Deg, 'deg');
r0Rad = nomoto_utils.rateToRad(r0DegPerSec, 'deg/s');

%% ======================== 非线性 Nomoto 仿真 ========================

% 先根据非线性 Nomoto 模型求出艏摇角速度 r(t)
rRad = nomoto_utils.simulateNonlinearNomoto(time, deltaRad, K, T, alpha, r0Rad);

% 再对 r 积分得到航向角 psi(t)
psiRad = zeros(size(time));
psiRad(1) = psi0Rad;
for k = 1:(numel(time) - 1)
    localDt = time(k + 1) - time(k);
    psiRad(k + 1) = psiRad(k) + 0.5 * (rRad(k) + rRad(k + 1)) * localDt;
end

% 最后在恒定速度假设下计算二维轨迹
% 说明：
% psiRad 是“累计航向角”，它会随着时间持续积分增长或减小，
% 不会自动限制在 [-pi, pi] 或 [0, 2*pi) 范围内。
% 这种累计角适合内部动力学积分与轨迹计算。
x = zeros(size(time));
y = zeros(size(time));
x(1) = x0;
y(1) = y0;

for k = 1:(numel(time) - 1)
    localDt = time(k + 1) - time(k);
    psiMid = 0.5 * (psiRad(k) + psiRad(k + 1));
    x(k + 1) = x(k) + forwardSpeed * cos(psiMid) * localDt;
    y(k + 1) = y(k) + forwardSpeed * sin(psiMid) * localDt;
end

%% ======================== 转换为显示单位 ========================

rDisplay = nomoto_utils.rateFromRad(rRad, yawRateDisplayUnit);
psiDisplay = nomoto_utils.angleFromRad(psiRad, angleDisplayUnit);
psiDisplayWrapped = wrapAngleForDisplay(psiRad, angleDisplayUnit);
[xLimitsWithPadding, yLimitsWithPadding] = calcAutoCenteredAxisLimits(x, y);

%% ======================== 命令行输出主要结果 ========================

fprintf('===== 非线性 Nomoto 轨迹仿真 =====\n');
fprintf('K = %.8f\n', K);
fprintf('T = %.8f s\n', T);
fprintf('alpha = %.8f\n', alpha);
fprintf('forwardSpeed = %.4f m/s\n', forwardSpeed);
fprintf('rudderMode = %s\n', rudderMode);
fprintf('totalTime = %.3f s\n', totalTime);
fprintf('dt = %.3f s\n', dt);
fprintf('最终位置 = (%.4f, %.4f) m\n', x(end), y(end));
fprintf('最终累计航向角 = %.4f %s\n', psiDisplay(end), angleDisplayUnit);
fprintf('最终包角航向角 = %.4f %s\n', psiDisplayWrapped(end), angleDisplayUnit);
fprintf('最终艏摇角速度 = %.4f %s\n', rDisplay(end), yawRateDisplayUnit);

%% ======================== 图 1：舵角输入 ========================

figure('Name', 'Nomoto Simulation - Rudder Input', 'Color', 'w');
plot(time, deltaDeg, 'b-', 'LineWidth', 1.4);
grid on;
xlabel('时间 (s)');
ylabel('舵角 (deg)');
title('舵角输入时序');

%% ======================== 图 2：艏摇角速度与航向角 ========================

figure('Name', 'Nomoto Simulation - States', 'Color', 'w');
subplot(2, 1, 1);
plot(time, rDisplay, 'r-', 'LineWidth', 1.4);
grid on;
xlabel('时间 (s)');
ylabel(['艏摇角速度 (' yawRateDisplayUnit ')']);
title('艏摇角速度响应');

subplot(2, 1, 2);
plot(time, psiDisplayWrapped, 'k-', 'LineWidth', 1.4);
grid on;
xlabel('时间 (s)');
ylabel(['航向角 (' angleDisplayUnit ')']);
title('航向角变化（包角显示）');

%% ======================== 图 3：二维轨迹 ========================

figure('Name', 'Nomoto Simulation - XY Trajectory', 'Color', 'w');
plot(x, y, 'b-', 'LineWidth', 1.6, 'DisplayName', '轨迹');
hold on;
scatter(x(1), y(1), 60, 'g', 'filled', 'DisplayName', '起点');
scatter(x(end), y(end), 60, 'r', 'filled', 'DisplayName', '终点');

if showDirectionArrow && numel(x) >= 2
    arrowIndex = min(numel(x) - 1, max(2, floor(0.85 * numel(x))));
    quiver(x(arrowIndex), y(arrowIndex), ...
        x(arrowIndex + 1) - x(arrowIndex), y(arrowIndex + 1) - y(arrowIndex), ...
        0, 'Color', [0.85 0.2 0.2], 'LineWidth', 1.5, 'MaxHeadSize', 3, ...
        'DisplayName', '方向');
end

grid on;
axis equal;
xlim(xLimitsWithPadding);
ylim(yLimitsWithPadding);
xlabel('X 位置 (m)');
ylabel('Y 位置 (m)');
title({ ...
    '非线性 Nomoto 模型二维轨迹'; ...
    sprintf('U = %.2f m/s, K = %.6f, T = %.6f s, alpha = %.6f', forwardSpeed, K, T, alpha); ...
    sprintf('舵角模式 = %s', rudderMode) ...
    });
legend('Location', 'best');
hold off;

%% ======================== 图 4：轨迹与航向采样 ========================

figure('Name', 'Nomoto Simulation - Trajectory with Heading Samples', 'Color', 'w');
plot(x, y, 'Color', [0.2 0.45 0.8], 'LineWidth', 1.5, 'DisplayName', '轨迹');
hold on;
grid on;
axis equal;
xlim(xLimitsWithPadding);
ylim(yLimitsWithPadding);

sampleCount = 20;
sampleIndex = unique(round(linspace(1, numel(time), sampleCount)));
arrowLength = max(0.2, 0.04 * max(1, hypot(max(x) - min(x), max(y) - min(y))));

for idx = sampleIndex
    quiver(x(idx), y(idx), arrowLength * cos(psiRad(idx)), arrowLength * sin(psiRad(idx)), ...
        0, 'Color', [0.85 0.3 0.2], 'LineWidth', 1.0, 'MaxHeadSize', 2, 'HandleVisibility', 'off');
end

scatter(x(1), y(1), 50, 'g', 'filled', 'DisplayName', '起点');
scatter(x(end), y(end), 50, 'r', 'filled', 'DisplayName', '终点');
xlabel('X 位置 (m)');
ylabel('Y 位置 (m)');
title('轨迹与航向方向采样');
legend('Location', 'best');
hold off;

%% ======================== 可选：简单动画 ========================

if enableAnimation
    figure('Name', 'Nomoto Simulation - Animation', 'Color', 'w');
    axis equal;
    grid on;
    hold on;
    xlabel('X 位置 (m)');
    ylabel('Y 位置 (m)');
    title('二维轨迹动画');
    xlim(xLimitsWithPadding);
    ylim(yLimitsWithPadding);

    plot(x, y, 'Color', [0.8 0.8 0.8], 'LineWidth', 1.0, 'DisplayName', '轨迹');
    animatedPath = plot(x(1), y(1), 'b-', 'LineWidth', 1.6, 'DisplayName', '已走轨迹');
    boatBody = plot(nan, nan, 'r-', 'LineWidth', 2.0, 'DisplayName', '船体朝向');
    legend('Location', 'best');

    for k = 1:animationStep:numel(time)
        set(animatedPath, 'XData', x(1:k), 'YData', y(1:k));

        bowX = x(k) + boatLengthForAnimation * cos(psiRad(k));
        bowY = y(k) + boatLengthForAnimation * sin(psiRad(k));
        set(boatBody, 'XData', [x(k), bowX], 'YData', [y(k), bowY]);

        drawnow;
    end
end

%% ======================== 本地函数区 ========================

function [xLimits, yLimits] = calcAutoCenteredAxisLimits(x, y)
% 根据轨迹自动生成“居中 + 四周留白”的正方形坐标轴范围。
% 这样在 axis equal 下，轨迹会更自然地显示在图中央，
% 四周会自动保留一定空白，不需要手动调整参数。

    xMin = min(x);
    xMax = max(x);
    yMin = min(y);
    yMax = max(y);

    centerX = 0.5 * (xMin + xMax);
    centerY = 0.5 * (yMin + yMax);

    xRange = xMax - xMin;
    yRange = yMax - yMin;
    maxRange = max(xRange, yRange);

    if maxRange < 1e-6
        maxRange = 1.0;
    end

    fullSpan = maxRange * 1.18;
    halfSpan = 0.5 * fullSpan;

    xLimits = [centerX - halfSpan, centerX + halfSpan];
    yLimits = [centerY - halfSpan, centerY + halfSpan];
end

function wrappedAngle = wrapAngleForDisplay(angleRad, angleUnit)
% 将累计航向角转换为更适合显示的包角形式。
% - 若显示单位为 deg，则输出范围为 [-180, 180)
% - 若显示单位为 rad，则输出范围为 [-pi, pi)
% 注意：这里只用于显示，不参与动力学积分。

    angleUnit = lower(strtrim(char(string(angleUnit))));

    switch angleUnit
        case {'deg', 'degree', 'degrees', '°'}
            wrappedAngle = mod(rad2deg(angleRad) + 180, 360) - 180;
        case {'rad', 'radian', 'radians'}
            wrappedAngle = mod(angleRad + pi, 2 * pi) - pi;
        otherwise
            convertedAngle = nomoto_utils.angleFromRad(angleRad, angleUnit);
            wrappedAngle = mod(convertedAngle + 180, 360) - 180;
    end
end

function deltaDeg = generateRudderInput(time, rudderMode, ...
    constantDeltaDeg, ...
    stepStartTime, initialStepDeltaDeg, finalStepDeltaDeg, ...
    sinBiasDeg, sinAmplitudeDeg, sinFrequencyHz, ...
    piecewiseTimeBreaks, piecewiseDeltaDeg, ...
    customRudderTime, customRudderDeg)
% 根据指定模式生成舵角时序（单位：deg）。

    rudderMode = lower(strtrim(char(string(rudderMode))));
    deltaDeg = zeros(size(time));

    switch rudderMode
        case 'constant'
            deltaDeg(:) = constantDeltaDeg;

        case 'step'
            deltaDeg(:) = initialStepDeltaDeg;
            deltaDeg(time >= stepStartTime) = finalStepDeltaDeg;

        case 'sin'
            deltaDeg = sinBiasDeg + sinAmplitudeDeg * sin(2 * pi * sinFrequencyHz * time);

        case 'piecewise'
            if numel(piecewiseTimeBreaks) ~= numel(piecewiseDeltaDeg)
                error('piecewiseTimeBreaks 与 piecewiseDeltaDeg 的长度必须一致。');
            end

            deltaDeg(:) = piecewiseDeltaDeg(end);
            for i = 1:(numel(piecewiseTimeBreaks) - 1)
                currentMask = time >= piecewiseTimeBreaks(i) & time < piecewiseTimeBreaks(i + 1);
                deltaDeg(currentMask) = piecewiseDeltaDeg(i);
            end
            deltaDeg(time < piecewiseTimeBreaks(1)) = piecewiseDeltaDeg(1);
            deltaDeg(time >= piecewiseTimeBreaks(end)) = piecewiseDeltaDeg(end);

        case 'custom'
            if numel(customRudderTime) ~= numel(customRudderDeg)
                error('customRudderTime 与 customRudderDeg 的长度必须一致。');
            end
            deltaDeg = interp1(customRudderTime(:), customRudderDeg(:), time, 'linear', 'extrap');

        otherwise
            error('rudderMode 仅支持 constant / step / sin / piecewise / custom。');
    end
end
