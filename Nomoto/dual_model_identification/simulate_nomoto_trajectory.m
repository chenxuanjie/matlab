%% 非线性 Nomoto 模型轨迹仿真脚本
% 模型形式：
%   T * dr/dt + r + alpha * r^3 = K * (u(t) - u_trim)
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
% 直接输入不同半 PWM 差值形式，查看模型在平面中的运动趋势。
% 同时支持：
% 1. 单模型：使用单个 K
% 2. 双模型：使用 K+ / K- 两个分支增益，并绘制正反两个回转圆
%
% 功能包括：
% 1. 绘制艏摇角速度响应
% 2. 绘制航向角变化
% 3. 绘制二维平面轨迹
% 4. 双模型时绘制正向/反向两个回转圆并统计半径
% 5. 可选地播放简单动画
%
% 说明：
% - 默认初始速度为 1 m/s，可直接在参数区修改。
% - 输入量使用“半 PWM 差值”：
%     u = 0.5 * (right_pwm - left_pwm)
% - 模型内部实际使用：
%     u_model = u - u_trim
% - 双模型模式下，K+ 作用于 u_model >= 0，K- 作用于 u_model < 0。

clc;
clear;
close all;

%% ======================== 模型参数区 ========================

% 模型模式：
% 'single' -> 单模型，只使用 K
% 'dual'   -> 双模型，使用 K+ / K-
modelMode = 'dual';

% 单模型参数：默认与 identify_nomoto_stages.m 中的验证参数口径一致
K = 0.00660955;

% 双模型参数：仅在 modelMode = 'dual' 时使用
KPos = 0.00613037509614;
KNeg = 0.00692732798839;

T = 0.492017530532;
alpha = 0.624713238232;

% 直行补偿所需的半 PWM 差值，逆时针为正
uTrim = 0;

%% ======================== 仿真参数区 ========================

% 仿真总时长（秒）
totalTime = 120;

% 时间步长（秒）
dt = 0.1;

% 恒定前进速度（m/s）
forwardSpeed = 1.277;

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

%% ======================== 半 PWM 差值输入配置区 ========================

% 半 PWM 差值输入模式：
% 'constant'  : 常值半 PWM 差值
% 'step'      : 阶跃半 PWM 差值
% 'sin'       : 正弦半 PWM 差值
% 'piecewise' : 分段常值半 PWM 差值
% 'custom'    : 自定义时变半 PWM 差值（线性插值）
%
% 说明：
% - 单模型模式下，严格按下面配置生成原始半 PWM 差值输入 uPwm。
% - 模型内部实际使用 uModelPwm = uPwm - uTrim。
% - 双模型模式下，为了同时展示正向/反向两个回转圆，
%   这里的 inputMode 会被忽略，脚本改为自动生成
%   uPwm = uTrim +/- dualTurnHalfPwmAmplitude 两条定值轨迹。
inputMode = 'step';

% 1) constant 模式：整个仿真过程半 PWM 差值保持不变
constantHalfPwm = 30;

% 2) step 模式：stepStartTime 之前为 initialStepHalfPwm，之后变为 finalStepHalfPwm
stepStartTime = 10;
initialStepHalfPwm = 0;
finalStepHalfPwm = 30;

% 3) sin 模式：
% uPwm(t) = sinBiasHalfPwm + sinAmplitudeHalfPwm * sin(2*pi*sinFrequencyHz*t)
sinBiasHalfPwm = 0;
sinAmplitudeHalfPwm = 30;
sinFrequencyHz = 0.02;

% 4) piecewise 模式：每个时间区间内保持常值
piecewiseTimeBreaks = [0, 20, 40, 60, 80];
piecewiseHalfPwm = [0, 10, 20, -15, 0];

% 5) custom 模式：按给定时间点和半 PWM 差值点进行线性插值
customInputTime = [0, 10, 20, 40, 60, 90, 120];
customHalfPwm = [0, 5, 15, 30, 10, -10, 0];

% 双模型模式下，围绕 uTrim 对称施加的半 PWM 差值幅值
dualTurnHalfPwmAmplitude = 30;

% 双模型模式下，取轨迹尾段多少比例的数据来拟合圆
circleFitTailFraction = 0.35;

%% ======================== 显示单位设置 ========================

angleDisplayUnit = 'deg';
yawRateDisplayUnit = 'deg/s';

%% ======================== 输入合法性检查 ========================

modelMode = parseModelMode(modelMode);

if totalTime <= 0
    error('totalTime 必须大于 0。');
end

if dt <= 0
    error('dt 必须大于 0。');
end

if T <= 0
    error('T 必须大于 0。');
end

if ~isfinite(forwardSpeed) || forwardSpeed < 0
    error('forwardSpeed 必须为非负有限值。');
end

if ~(isfinite(circleFitTailFraction) && circleFitTailFraction > 0 && circleFitTailFraction <= 1)
    error('circleFitTailFraction 必须在 (0, 1] 范围内。');
end

%% ======================== 生成时间轴与半 PWM 差值输入 ========================

time = (0:dt:totalTime).';
psi0Rad = nomoto_utils.angleToRad(psi0Deg, 'deg');
r0Rad = nomoto_utils.rateToRad(r0DegPerSec, 'deg/s');

%% ======================== 非线性 Nomoto 仿真 ========================

switch modelMode
    case 'single'
        if ~(isfinite(K) && isscalar(K))
            error('单模型模式下，K 必须为有限标量。');
        end

        uPwm = generateHalfPwmInput(time, inputMode, ...
            constantHalfPwm, ...
            stepStartTime, initialStepHalfPwm, finalStepHalfPwm, ...
            sinBiasHalfPwm, sinAmplitudeHalfPwm, sinFrequencyHz, ...
            piecewiseTimeBreaks, piecewiseHalfPwm, ...
            customInputTime, customHalfPwm);

        scenarios = simulateTrajectoryScenario( ...
            time, uPwm, uTrim, K, T, alpha, ...
            forwardSpeed, x0, y0, psi0Rad, r0Rad, ...
            angleDisplayUnit, yawRateDisplayUnit, ...
            '主轨迹', [0.15 0.42 0.84], [0.15 0.42 0.84], [0.85 0.25 0.20]);

        circleInfos = struct([]);
        [xLimitsWithPadding, yLimitsWithPadding] = calcAutoCenteredAxisLimits(scenarios(1).x, scenarios(1).y);

    case 'dual'
        if ~(isfinite(KPos) && isscalar(KPos))
            error('双模型模式下，KPos 必须为有限标量。');
        end
        if ~(isfinite(KNeg) && isscalar(KNeg))
            error('双模型模式下，KNeg 必须为有限标量。');
        end

        dualTurnHalfPwmAmplitude = abs(dualTurnHalfPwmAmplitude);
        if dualTurnHalfPwmAmplitude <= 0
            error('双模型模式下，dualTurnHalfPwmAmplitude 必须大于 0。');
        end

        gainSpec = struct('K_pos', KPos, 'K_neg', KNeg);

        scenarios(1) = simulateTrajectoryScenario( ...
            time, (uTrim + dualTurnHalfPwmAmplitude) * ones(size(time)), uTrim, gainSpec, T, alpha, ...
            forwardSpeed, x0, y0, psi0Rad, r0Rad, ...
            angleDisplayUnit, yawRateDisplayUnit, ...
            '正向支路', [0.12 0.38 0.88], [0.12 0.38 0.88], [0.12 0.60 0.95]);

        scenarios(2) = simulateTrajectoryScenario( ...
            time, (uTrim - dualTurnHalfPwmAmplitude) * ones(size(time)), uTrim, gainSpec, T, alpha, ...
            forwardSpeed, x0, y0, psi0Rad, r0Rad, ...
            angleDisplayUnit, yawRateDisplayUnit, ...
            '反向支路', [0.88 0.30 0.18], [0.88 0.30 0.18], [0.96 0.58 0.18]);

        circleInfos(1) = fitTurningCircleFromScenario(scenarios(1), circleFitTailFraction, forwardSpeed);
        circleInfos(2) = fitTurningCircleFromScenario(scenarios(2), circleFitTailFraction, forwardSpeed);
        [xLimitsWithPadding, yLimitsWithPadding] = calcAxisLimitsForScenarios(scenarios, circleInfos);
end

%% ======================== 命令行输出主要结果 ========================

fprintf('===== 非线性 Nomoto 轨迹仿真 =====\n');
fprintf('modelMode = %s\n', modelMode);
fprintf('T = %.8f s\n', T);
fprintf('alpha = %.8f\n', alpha);
fprintf('forwardSpeed = %.4f m/s\n', forwardSpeed);
fprintf('totalTime = %.3f s\n', totalTime);
fprintf('dt = %.3f s\n', dt);
fprintf('uTrim = %.4f\n', uTrim);

switch modelMode
    case 'single'
        fprintf('K = %.8f\n', K);
        fprintf('inputMode = %s\n', inputMode);
        fprintf('最终原始半 PWM 差值 = %.4f\n', scenarios(1).uPwm(end));
        fprintf('最终修正后半 PWM 差值 = %.4f\n', scenarios(1).uModelPwm(end));
        fprintf('最终位置 = (%.4f, %.4f) m\n', scenarios(1).x(end), scenarios(1).y(end));
        fprintf('最终累计航向角 = %.4f %s\n', scenarios(1).psiDisplay(end), angleDisplayUnit);
        fprintf('最终包角航向角 = %.4f %s\n', scenarios(1).psiDisplayWrapped(end), angleDisplayUnit);
        fprintf('最终艏摇角速度 = %.4f %s\n', scenarios(1).rDisplay(end), yawRateDisplayUnit);

    case 'dual'
        fprintf('K+ = %.8f\n', KPos);
        fprintf('K- = %.8f\n', KNeg);
        fprintf('双模型定值半 PWM 差值幅值 = %.4f\n', dualTurnHalfPwmAmplitude);

        for i = 1:numel(scenarios)
            fprintf('%s最终原始半 PWM 差值 = %.4f\n', scenarios(i).label, scenarios(i).uPwm(end));
            fprintf('%s最终修正后半 PWM 差值 = %.4f\n', scenarios(i).label, scenarios(i).uModelPwm(end));
            fprintf('%s最终位置 = (%.4f, %.4f) m\n', scenarios(i).label, scenarios(i).x(end), scenarios(i).y(end));
            fprintf('%s最终累计航向角 = %.4f %s\n', scenarios(i).label, scenarios(i).psiDisplay(end), angleDisplayUnit);
            fprintf('%s最终包角航向角 = %.4f %s\n', scenarios(i).label, scenarios(i).psiDisplayWrapped(end), angleDisplayUnit);
            fprintf('%s最终艏摇角速度 = %.4f %s\n', scenarios(i).label, scenarios(i).rDisplay(end), yawRateDisplayUnit);

            if circleInfos(i).valid
                fprintf('%s回转圆半径 = %.4f m\n', scenarios(i).label, circleInfos(i).radius);
            elseif isfinite(circleInfos(i).steadyRadius)
                fprintf('%s回转圆半径（尾段角速度估计） = %.4f m\n', scenarios(i).label, circleInfos(i).steadyRadius);
            else
                fprintf('%s回转圆半径 = NaN（圆拟合失败）\n', scenarios(i).label);
            end
        end
end

%% ======================== 图 1：艏摇角速度与航向角 ========================

figure('Name', 'Nomoto Simulation - States', 'Color', 'w');
subplot(2, 1, 1);
hold on;
for i = 1:numel(scenarios)
    plot(time, scenarios(i).rDisplay, '-', 'Color', scenarios(i).stateColor, ...
        'LineWidth', 1.4, 'DisplayName', scenarios(i).label);
end
grid on;
xlabel('时间 (s)');
ylabel(['艏摇角速度 (' yawRateDisplayUnit ')']);
if strcmp(modelMode, 'dual')
    legend('Location', 'best');
else
end
hold off;

subplot(2, 1, 2);
hold on;
for i = 1:numel(scenarios)
    plot(time, scenarios(i).psiDisplayWrapped, '-', 'Color', scenarios(i).stateColor, ...
        'LineWidth', 1.4, 'DisplayName', scenarios(i).label);
end
grid on;
xlabel('时间 (s)');
ylabel(['航向角 (' angleDisplayUnit ')']);
if strcmp(modelMode, 'dual')
    legend('Location', 'best');
else
end
hold off;

%% ======================== 图 2：二维轨迹 ========================

if ~strcmp(modelMode, 'dual')
    figure('Name', 'Nomoto Simulation - XY Trajectory', 'Color', 'w');
    hold on;
    for i = 1:numel(scenarios)
        plot(scenarios(i).x, scenarios(i).y, '-', 'Color', scenarios(i).trajectoryColor, ...
            'LineWidth', 1.6, 'DisplayName', [scenarios(i).label '轨迹']);
    end

    scatter(scenarios(1).x(1), scenarios(1).y(1), 60, 'g', 'filled', 'DisplayName', '起点');
    for i = 1:numel(scenarios)
        scatter(scenarios(i).x(end), scenarios(i).y(end), 60, ...
            scenarios(i).trajectoryColor, 'filled', 'DisplayName', [scenarios(i).label '终点']);
    end

    if showDirectionArrow
        for i = 1:numel(scenarios)
            if numel(scenarios(i).x) < 2
                continue;
            end
            arrowIndex = min(numel(scenarios(i).x) - 1, max(2, floor(0.85 * numel(scenarios(i).x))));
            quiver(scenarios(i).x(arrowIndex), scenarios(i).y(arrowIndex), ...
                scenarios(i).x(arrowIndex + 1) - scenarios(i).x(arrowIndex), ...
                scenarios(i).y(arrowIndex + 1) - scenarios(i).y(arrowIndex), ...
                0, 'Color', scenarios(i).arrowColor, 'LineWidth', 1.5, 'MaxHeadSize', 3, ...
                'DisplayName', [scenarios(i).label '方向']);
        end
    end

    grid on;
    axis equal;
    xlim(xLimitsWithPadding);
    ylim(yLimitsWithPadding);
    xlabel('横向位置 (m)');
    ylabel('纵向位置 (m)');
    legend('Location', 'best');
    hold off;
end

%% ======================== 图 3：轨迹与航向采样 ========================

if strcmp(modelMode, 'dual')
    figure('Name', 'Nomoto Simulation - Dual Model XY Trajectory and Turning Circle', 'Color', 'w');
else
    figure('Name', 'Nomoto Simulation - Trajectory with Heading Samples', 'Color', 'w');
end
hold on;
grid on;
axis equal;
xlim(xLimitsWithPadding);
ylim(yLimitsWithPadding);

sampleCount = 20;
allX = vertcat(scenarios.x);
allY = vertcat(scenarios.y);
arrowLength = max(0.2, 0.04 * max(1, hypot(max(allX) - min(allX), max(allY) - min(allY))));

for i = 1:numel(scenarios)
    plot(scenarios(i).x, scenarios(i).y, 'Color', scenarios(i).trajectoryColor, ...
        'LineWidth', 1.5, 'DisplayName', [scenarios(i).label '轨迹']);

    sampleIndex = unique(round(linspace(1, numel(time), sampleCount)));
    for idx = sampleIndex
        quiver(scenarios(i).x(idx), scenarios(i).y(idx), ...
            arrowLength * cos(scenarios(i).psiRad(idx)), ...
            arrowLength * sin(scenarios(i).psiRad(idx)), ...
            0, 'Color', scenarios(i).arrowColor, 'LineWidth', 1.0, ...
            'MaxHeadSize', 2, 'HandleVisibility', 'off');
    end
end

if strcmp(modelMode, 'dual')
    for i = 1:numel(circleInfos)
        if circleInfos(i).valid
            plotTurningCircle(circleInfos(i), scenarios(i).arrowColor, ...
                [scenarios(i).label '拟合圆']);
        end
    end
end

scatter(scenarios(1).x(1), scenarios(1).y(1), 50, 'g', 'filled', 'DisplayName', '起点');
for i = 1:numel(scenarios)
    scatter(scenarios(i).x(end), scenarios(i).y(end), 50, ...
        scenarios(i).trajectoryColor, 'filled', 'DisplayName', [scenarios(i).label '终点']);
end
xlabel('横向位置 (m)');
ylabel('纵向位置 (m)');
if strcmp(modelMode, 'dual')
else
end
legend('Location', 'best');
hold off;

%% ======================== 可选：简单动画 ========================

if enableAnimation
    figure('Name', 'Nomoto Simulation - Animation', 'Color', 'w');
    axis equal;
    grid on;
    hold on;
    xlabel('横向位置 (m)');
    ylabel('纵向位置 (m)');
    xlim(xLimitsWithPadding);
    ylim(yLimitsWithPadding);

    animatedPath = gobjects(numel(scenarios), 1);
    boatBody = gobjects(numel(scenarios), 1);
    for i = 1:numel(scenarios)
        plot(scenarios(i).x, scenarios(i).y, 'Color', 0.85 * [1 1 1], ...
            'LineWidth', 1.0, 'HandleVisibility', 'off');
        animatedPath(i) = plot(scenarios(i).x(1), scenarios(i).y(1), '-', ...
            'Color', scenarios(i).trajectoryColor, 'LineWidth', 1.6, ...
            'DisplayName', [scenarios(i).label '已走轨迹']);
        boatBody(i) = plot(nan, nan, '-', 'Color', scenarios(i).arrowColor, ...
            'LineWidth', 2.0, 'DisplayName', [scenarios(i).label '船体朝向']);
    end
    legend('Location', 'best');

    for k = 1:animationStep:numel(time)
        for i = 1:numel(scenarios)
            set(animatedPath(i), 'XData', scenarios(i).x(1:k), 'YData', scenarios(i).y(1:k));

            bowX = scenarios(i).x(k) + boatLengthForAnimation * cos(scenarios(i).psiRad(k));
            bowY = scenarios(i).y(k) + boatLengthForAnimation * sin(scenarios(i).psiRad(k));
            set(boatBody(i), 'XData', [scenarios(i).x(k), bowX], ...
                'YData', [scenarios(i).y(k), bowY]);
        end

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

function modeText = parseModelMode(rawMode)
% 解析模型模式，只支持 single / dual。

    modeText = lower(strtrim(char(string(rawMode))));
    switch modeText
        case {'single', 'dual'}
            return;
        otherwise
            error('modelMode 仅支持 ''single'' 或 ''dual''。');
    end
end

function scenario = simulateTrajectoryScenario(time, uPwm, uTrim, KSpec, T, alpha, ...
    forwardSpeed, x0, y0, psi0Rad, r0Rad, angleDisplayUnit, yawRateDisplayUnit, ...
    labelText, trajectoryColor, stateColor, arrowColor)
% 生成一个仿真场景，包括半 PWM 差值输入、状态响应与二维轨迹。

    uPwm = uPwm(:);
    uModelPwm = uPwm - uTrim;
    rRad = nomoto_utils.simulateNonlinearNomoto(time, uModelPwm, KSpec, T, alpha, r0Rad);
    psiRad = integrateHeadingFromYawRate(time, rRad, psi0Rad);
    [x, y] = integratePlanarTrajectory(time, psiRad, forwardSpeed, x0, y0);

    scenario = struct();
    scenario.time = time;
    scenario.label = labelText;
    scenario.uPwm = uPwm;
    scenario.uModelPwm = uModelPwm;
    scenario.uTrim = uTrim;
    scenario.rRad = rRad(:);
    scenario.psiRad = psiRad(:);
    scenario.x = x(:);
    scenario.y = y(:);
    scenario.rDisplay = nomoto_utils.rateFromRad(rRad, yawRateDisplayUnit);
    scenario.psiDisplay = nomoto_utils.angleFromRad(psiRad, angleDisplayUnit);
    scenario.psiDisplayWrapped = wrapAngleForDisplay(psiRad, angleDisplayUnit);
    scenario.trajectoryColor = trajectoryColor;
    scenario.stateColor = stateColor;
    scenario.arrowColor = arrowColor;
end

function psiRad = integrateHeadingFromYawRate(time, rRad, psi0Rad)
% 对艏摇角速度积分，得到累计航向角。

    psiRad = zeros(size(time));
    psiRad(1) = psi0Rad;

    for k = 1:(numel(time) - 1)
        localDt = time(k + 1) - time(k);
        psiRad(k + 1) = psiRad(k) + 0.5 * (rRad(k) + rRad(k + 1)) * localDt;
    end
end

function [x, y] = integratePlanarTrajectory(time, psiRad, forwardSpeed, x0, y0)
% 在恒定前进速度假设下积分得到二维轨迹。

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
end

function circleInfo = fitTurningCircleFromScenario(scenario, tailFraction, forwardSpeed)
% 用轨迹尾段拟合回转圆，并给出半径估计。

    tailIdx = buildTailIndices(numel(scenario.x), tailFraction);
    xTail = scenario.x(tailIdx);
    yTail = scenario.y(tailIdx);

    [centerX, centerY, radius, rmseValue, isValid] = fitCircleLeastSquares(xTail, yTail);
    meanTailYawRate = mean(scenario.rRad(tailIdx), 'omitnan');

    circleInfo = struct();
    circleInfo.valid = isValid;
    circleInfo.centerX = centerX;
    circleInfo.centerY = centerY;
    circleInfo.radius = radius;
    circleInfo.rmse = rmseValue;
    circleInfo.tailStartIndex = tailIdx(1);
    circleInfo.tailEndIndex = tailIdx(end);
    circleInfo.steadyRadius = estimateTurningRadius(forwardSpeed, meanTailYawRate);
end

function tailIdx = buildTailIndices(sampleCount, tailFraction)
% 返回尾段采样索引。

    tailCount = max(ceil(sampleCount * tailFraction), 20);
    tailCount = min(tailCount, sampleCount);
    tailStart = sampleCount - tailCount + 1;
    tailIdx = (tailStart:sampleCount).';
end

function [centerX, centerY, radius, rmseValue, isValid] = fitCircleLeastSquares(x, y)
% 采用最小二乘方法拟合圆。

    centerX = NaN;
    centerY = NaN;
    radius = NaN;
    rmseValue = NaN;
    isValid = false;

    x = x(:);
    y = y(:);

    if numel(x) < 3 || numel(y) < 3
        return;
    end

    A = [2 * x, 2 * y, ones(size(x))];
    b = x.^2 + y.^2;

    if rank(A) < 3
        return;
    end

    coeff = A \ b;
    centerX = coeff(1);
    centerY = coeff(2);
    radiusSquared = coeff(3) + centerX^2 + centerY^2;

    if ~(isfinite(radiusSquared) && radiusSquared > 0)
        centerX = NaN;
        centerY = NaN;
        return;
    end

    radius = sqrt(radiusSquared);
    radialError = hypot(x - centerX, y - centerY) - radius;
    rmseValue = sqrt(mean(radialError.^2, 'omitnan'));
    isValid = isfinite(centerX) && isfinite(centerY) && isfinite(radius);
end

function plotTurningCircle(circleInfo, colorSpec, ~)
% 绘制拟合得到的回转圆。

    theta = linspace(0, 2 * pi, 361);
    circleX = circleInfo.centerX + circleInfo.radius * cos(theta);
    circleY = circleInfo.centerY + circleInfo.radius * sin(theta);

    plot(circleX, circleY, '--', 'Color', colorSpec, 'LineWidth', 1.2, ...
        'HandleVisibility', 'off');
end

function [xLimits, yLimits] = calcAxisLimitsForScenarios(scenarios, circleInfos)
% 根据所有轨迹及拟合圆共同确定坐标轴范围。

    allX = vertcat(scenarios.x);
    allY = vertcat(scenarios.y);

    for i = 1:numel(circleInfos)
        if ~circleInfos(i).valid
            continue;
        end

        allX = [allX; circleInfos(i).centerX - circleInfos(i).radius; circleInfos(i).centerX + circleInfos(i).radius]; %#ok<AGROW>
        allY = [allY; circleInfos(i).centerY - circleInfos(i).radius; circleInfos(i).centerY + circleInfos(i).radius]; %#ok<AGROW>
    end

    [xLimits, yLimits] = calcAutoCenteredAxisLimits(allX, allY);
end

function radiusM = estimateTurningRadius(speedMps, yawRateRadS)
% 根据稳态角速度估计回转半径。

    if ~(isfinite(speedMps) && isfinite(yawRateRadS) && abs(yawRateRadS) > eps)
        radiusM = NaN;
    else
        radiusM = abs(speedMps / yawRateRadS);
    end
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

function uPwm = generateHalfPwmInput(time, inputMode, ...
    constantHalfPwm, ...
    stepStartTime, initialStepHalfPwm, finalStepHalfPwm, ...
    sinBiasHalfPwm, sinAmplitudeHalfPwm, sinFrequencyHz, ...
    piecewiseTimeBreaks, piecewiseHalfPwm, ...
    customInputTime, customHalfPwm)
% 根据指定模式生成半 PWM 差值时序。

    inputMode = lower(strtrim(char(string(inputMode))));
    uPwm = zeros(size(time));

    switch inputMode
        case 'constant'
            uPwm(:) = constantHalfPwm;

        case 'step'
            uPwm(:) = initialStepHalfPwm;
            uPwm(time >= stepStartTime) = finalStepHalfPwm;

        case 'sin'
            uPwm = sinBiasHalfPwm + sinAmplitudeHalfPwm * sin(2 * pi * sinFrequencyHz * time);

        case 'piecewise'
            if numel(piecewiseTimeBreaks) ~= numel(piecewiseHalfPwm)
                error('piecewiseTimeBreaks 与 piecewiseHalfPwm 的长度必须一致。');
            end

            uPwm(:) = piecewiseHalfPwm(end);
            for i = 1:(numel(piecewiseTimeBreaks) - 1)
                currentMask = time >= piecewiseTimeBreaks(i) & time < piecewiseTimeBreaks(i + 1);
                uPwm(currentMask) = piecewiseHalfPwm(i);
            end
            uPwm(time < piecewiseTimeBreaks(1)) = piecewiseHalfPwm(1);
            uPwm(time >= piecewiseTimeBreaks(end)) = piecewiseHalfPwm(end);

        case 'custom'
            if numel(customInputTime) ~= numel(customHalfPwm)
                error('customInputTime 与 customHalfPwm 的长度必须一致。');
            end
            uPwm = interp1(customInputTime(:), customHalfPwm(:), time, 'linear', 'extrap');

        otherwise
            error('inputMode 仅支持 constant / step / sin / piecewise / custom。');
    end
end
