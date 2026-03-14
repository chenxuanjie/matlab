classdef nomoto_utils
    % nomoto_utils
    % 公共工具类：
    % 1. 读取和预处理 Nomoto 参数识别数据
    % 2. 支持表格型文件和 key=value 日志文件
    % 3. 提供舵角分段、稳态点提取、线性/非线性 Nomoto 仿真等功能

    methods(Static)
        function data = readData(cfg)
            % readData
            % 根据配置读取 time / delta / r 三列数据，并完成：
            % - 删除无效数据
            % - 按时间排序
            % - 单位统一为 rad 和 rad/s
            % - 可选的时间窗口截取
            % - 可选的移动平均滤波

            nomoto_utils.assertRequiredFields(cfg, ...
                {'dataFile', 'readMode', 'timeColumn', 'deltaColumn', 'rColumn', 'angleUnit', 'yawRateUnit'});

            if ~isfile(cfg.dataFile)
                error('找不到数据文件：%s', cfg.dataFile);
            end

            readMode = lower(string(cfg.readMode));
            sourceMode = '';

            switch readMode
                case "auto"
                    try
                        [time, delta, r] = nomoto_utils.readFromTable(cfg);
                        sourceMode = 'table';
                    catch
                        [time, delta, r] = nomoto_utils.readFromKeyValue(cfg);
                        sourceMode = 'keyvalue';
                    end
                case "table"
                    [time, delta, r] = nomoto_utils.readFromTable(cfg);
                    sourceMode = 'table';
                case "keyvalue"
                    [time, delta, r] = nomoto_utils.readFromKeyValue(cfg);
                    sourceMode = 'keyvalue';
                otherwise
                    error('readMode 仅支持 auto / table / keyvalue。');
            end

            time = nomoto_utils.ensureColumn(time);
            delta = nomoto_utils.ensureColumn(delta);
            r = nomoto_utils.ensureColumn(r);

            validMask = isfinite(time) & isfinite(delta) & isfinite(r);
            time = time(validMask);
            delta = delta(validMask);
            r = r(validMask);

            if isempty(time)
                error('读取后没有有效数据，请检查文件内容和列配置。');
            end

            [time, sortIdx] = sort(time);
            delta = delta(sortIdx);
            r = r(sortIdx);

            if isfield(cfg, 'enableTimeWindow') && cfg.enableTimeWindow
                if ~isfield(cfg, 'timeWindow') || numel(cfg.timeWindow) ~= 2
                    error('开启时间窗口后，必须提供 cfg.timeWindow = [tStart, tEnd]。');
                end

                tStart = cfg.timeWindow(1);
                tEnd = cfg.timeWindow(2);
                windowMask = time >= tStart & time <= tEnd;

                time = time(windowMask);
                delta = delta(windowMask);
                r = r(windowMask);

                if isempty(time)
                    error('时间窗口内没有有效数据，请检查 cfg.timeWindow 设置。');
                end
            end

            deltaRad = nomoto_utils.angleToRad(delta, cfg.angleUnit);
            rRad = nomoto_utils.rateToRad(r, cfg.yawRateUnit);

            data = struct();
            data.time = time;
            data.deltaRaw = deltaRad;
            data.rRaw = rRad;
            data.delta = deltaRad;
            data.r = rRad;
            data.sourceMode = sourceMode;
            data.sampleCount = numel(time);

            if isfield(cfg, 'enableFilter') && cfg.enableFilter
                if ~isfield(cfg, 'filterWindow')
                    cfg.filterWindow = 5;
                end

                windowSize = max(1, round(cfg.filterWindow));
                if windowSize > 1
                    data.delta = movmean(data.delta, windowSize, 'Endpoints', 'shrink');
                    data.r = movmean(data.r, windowSize, 'Endpoints', 'shrink');
                end
            end
        end

        function [time, delta, r] = readFromTable(cfg)
            % readFromTable
            % 适用于 csv / txt / xlsx 等能被 readtable 正常读取的文件。
            % timeColumn / deltaColumn / rColumn 可以是列名，也可以是列序号。

            if isfield(cfg, 'tableDelimiter') && ~isempty(cfg.tableDelimiter)
                tbl = readtable(cfg.dataFile, 'Delimiter', cfg.tableDelimiter);
            else
                tbl = readtable(cfg.dataFile);
            end

            time = nomoto_utils.extractTableColumn(tbl, cfg.timeColumn);
            delta = nomoto_utils.extractTableColumn(tbl, cfg.deltaColumn);
            r = nomoto_utils.extractTableColumn(tbl, cfg.rColumn);
        end

        function [time, delta, r] = readFromKeyValue(cfg)
            % readFromKeyValue
            % 适用于每行形如：
            % time=0.0,delta=5.0,r=0.12

            if ~ischar(cfg.timeColumn) && ~isstring(cfg.timeColumn)
                error('keyvalue 模式下，timeColumn 必须是字符串字段名。');
            end
            if ~ischar(cfg.deltaColumn) && ~isstring(cfg.deltaColumn)
                error('keyvalue 模式下，deltaColumn 必须是字符串字段名。');
            end
            if ~ischar(cfg.rColumn) && ~isstring(cfg.rColumn)
                error('keyvalue 模式下，rColumn 必须是字符串字段名。');
            end

            fileText = fileread(cfg.dataFile);
            rawLines = regexp(fileText, '\r\n|\n|\r', 'split');

            time = [];
            delta = [];
            r = [];

            for i = 1:numel(rawLines)
                oneLine = strtrim(rawLines{i});
                if isempty(oneLine)
                    continue;
                end

                currentTime = nomoto_utils.extractKeyValue(oneLine, char(cfg.timeColumn));
                currentDelta = nomoto_utils.extractKeyValue(oneLine, char(cfg.deltaColumn));
                currentR = nomoto_utils.extractKeyValue(oneLine, char(cfg.rColumn));

                if ~(isnan(currentTime) || isnan(currentDelta) || isnan(currentR))
                    time(end + 1, 1) = currentTime; %#ok<AGROW>
                    delta(end + 1, 1) = currentDelta; %#ok<AGROW>
                    r(end + 1, 1) = currentR; %#ok<AGROW>
                end
            end

            if isempty(time)
                error('keyvalue 模式未解析到有效数据，请检查字段名和日志格式。');
            end
        end

        function values = extractTableColumn(tbl, columnSpec)
            % extractTableColumn
            % 支持按列名或列号取数据列。

            if isnumeric(columnSpec)
                columnIndex = round(columnSpec);
                if columnIndex < 1 || columnIndex > size(tbl, 2)
                    error('列序号 %d 超出表格范围。', columnIndex);
                end
                values = tbl{:, columnIndex};
                values = nomoto_utils.convertColumnToNumeric(values);
                return;
            end

            columnName = char(string(columnSpec));
            variableNames = tbl.Properties.VariableNames;

            % 先做精确匹配
            exactMatch = strcmp(variableNames, columnName);
            if any(exactMatch)
                values = tbl{:, find(exactMatch, 1, 'first')};
                values = nomoto_utils.convertColumnToNumeric(values);
                return;
            end

            % 再做大小写不敏感匹配
            caseMatch = strcmpi(variableNames, columnName);
            if any(caseMatch)
                values = tbl{:, find(caseMatch, 1, 'first')};
                values = nomoto_utils.convertColumnToNumeric(values);
                return;
            end

            % 尝试 MATLAB 自动合法化后的变量名
            safeName = matlab.lang.makeValidName(columnName);
            exactSafeMatch = strcmp(variableNames, safeName);
            if any(exactSafeMatch)
                values = tbl{:, find(exactSafeMatch, 1, 'first')};
                values = nomoto_utils.convertColumnToNumeric(values);
                return;
            end

            error('在表格中找不到列：%s', columnName);
        end

        function values = convertColumnToNumeric(values)
            % convertColumnToNumeric
            % 将 table 列转换为数值列向量。

            if istable(values)
                values = table2array(values);
            end

            if iscell(values)
                values = str2double(values);
            elseif isstring(values)
                values = str2double(values);
            elseif ischar(values)
                values = str2double(cellstr(values));
            end

            values = nomoto_utils.ensureColumn(values);
        end

        function value = extractKeyValue(oneLine, keyName)
            % extractKeyValue
            % 从单行 key=value 文本中提取数值。

            pattern = ['(?:^|[,;\s])\s*', regexptranslate('escape', keyName), ...
                '\s*=\s*([+-]?\d*\.?\d+(?:[eE][+-]?\d+)?)'];
            token = regexp(oneLine, pattern, 'tokens', 'once');

            if isempty(token)
                value = NaN;
            else
                value = str2double(token{1});
            end
        end

        function segments = splitByStepSegments(data, changeThresholdRad, smoothWindow, minSegmentSamples)
            % splitByStepSegments
            % 根据舵角变化来自动分段。
            % 当相邻样本平滑后舵角变化超过阈值时，认为进入新阶段。
            % 该方法适合阶跃舵角、分段恒定舵角试验。

            time = nomoto_utils.ensureColumn(data.time);
            delta = nomoto_utils.ensureColumn(data.delta);
            r = nomoto_utils.ensureColumn(data.r);

            if nargin < 3 || isempty(smoothWindow)
                smoothWindow = 1;
            end
            if nargin < 4 || isempty(minSegmentSamples)
                minSegmentSamples = 1;
            end

            smoothWindow = max(1, round(smoothWindow));
            if smoothWindow > 1
                deltaForSplit = movmean(delta, smoothWindow, 'Endpoints', 'shrink');
            else
                deltaForSplit = delta;
            end

            changeMask = abs(diff(deltaForSplit)) >= changeThresholdRad;
            boundaryIndex = [1; find(changeMask) + 1; numel(time) + 1];

            rawSegments = repmat(struct( ...
                'startIndex', [], ...
                'endIndex', [], ...
                'time', [], ...
                'delta', [], ...
                'r', [], ...
                'meanDelta', [], ...
                'duration', []), numel(boundaryIndex) - 1, 1);

            writeIndex = 0;
            for i = 1:(numel(boundaryIndex) - 1)
                startIdx = boundaryIndex(i);
                endIdx = boundaryIndex(i + 1) - 1;
                sampleCount = endIdx - startIdx + 1;

                if sampleCount < minSegmentSamples
                    continue;
                end

                writeIndex = writeIndex + 1;
                rawSegments(writeIndex).startIndex = startIdx;
                rawSegments(writeIndex).endIndex = endIdx;
                rawSegments(writeIndex).time = time(startIdx:endIdx);
                rawSegments(writeIndex).delta = delta(startIdx:endIdx);
                rawSegments(writeIndex).r = r(startIdx:endIdx);
                rawSegments(writeIndex).meanDelta = mean(delta(startIdx:endIdx));
                rawSegments(writeIndex).duration = time(endIdx) - time(startIdx);
            end

            segments = rawSegments(1:writeIndex);

            if isempty(segments)
                error('自动分段后没有保留下有效阶段，请调大 changeThreshold 或调小 minSegmentSamples。');
            end
        end

        function steady = extractSteadyPoints(segments, tailFraction, minSteadySamples)
            % extractSteadyPoints
            % 对每一段数据取尾部一部分样本，用平均值表示稳态点。

            segmentCount = numel(segments);
            steady = struct();
            steady.segmentIndex = (1:segmentCount).';
            steady.delta = zeros(segmentCount, 1);
            steady.r = zeros(segmentCount, 1);
            steady.pointCount = zeros(segmentCount, 1);
            steady.timeStart = zeros(segmentCount, 1);
            steady.timeEnd = zeros(segmentCount, 1);

            for i = 1:segmentCount
                currentDelta = segments(i).delta;
                currentR = segments(i).r;
                currentTime = segments(i).time;
                totalCount = numel(currentR);

                pointsFromFraction = ceil(totalCount * tailFraction);
                pointsToUse = max(pointsFromFraction, minSteadySamples);
                pointsToUse = min(pointsToUse, totalCount);

                startIdx = totalCount - pointsToUse + 1;
                tailIndex = startIdx:totalCount;

                steady.delta(i) = mean(currentDelta(tailIndex));
                steady.r(i) = mean(currentR(tailIndex));
                steady.pointCount(i) = pointsToUse;
                steady.timeStart(i) = currentTime(tailIndex(1));
                steady.timeEnd(i) = currentTime(tailIndex(end));
            end
        end

        function K = estimateKThroughOrigin(delta, r)
            % estimateKThroughOrigin
            % 使用过原点的最小二乘拟合 r = K * delta。

            numerator = sum(delta .* r);
            denominator = sum(delta .* delta);

            if denominator <= eps
                error('舵角数据全为 0 或过小，无法识别 K。');
            end

            K = numerator / denominator;
        end

        function rModel = simulateLinearNomoto(time, delta, K, T, r0)
            % simulateLinearNomoto
            % 线性一阶 Nomoto：T * dr/dt + r = K * delta
            % 采用“区间内舵角恒定”的解析离散更新。

            if T <= 0
                error('T 必须大于 0。');
            end

            time = nomoto_utils.ensureColumn(time);
            delta = nomoto_utils.ensureColumn(delta);

            sampleCount = numel(time);
            rModel = zeros(sampleCount, 1);
            rModel(1) = r0;

            for k = 1:(sampleCount - 1)
                dt = time(k + 1) - time(k);
                if dt <= 0
                    rModel(k + 1) = rModel(k);
                    continue;
                end

                decayFactor = exp(-dt / T);
                rModel(k + 1) = decayFactor * rModel(k) + K * delta(k) * (1 - decayFactor);
            end
        end

        function rModel = simulateNonlinearNomoto(time, delta, K, T, alpha, r0)
            % simulateNonlinearNomoto
            % 非线性模型：T * dr/dt + r + alpha * r^3 = K * delta
            % 使用四阶 Runge-Kutta 方法逐步积分。

            if T <= 0
                error('T 必须大于 0。');
            end

            time = nomoto_utils.ensureColumn(time);
            delta = nomoto_utils.ensureColumn(delta);

            sampleCount = numel(time);
            rModel = zeros(sampleCount, 1);
            rModel(1) = r0;

            for k = 1:(sampleCount - 1)
                dt = time(k + 1) - time(k);
                if dt <= 0
                    rModel(k + 1) = rModel(k);
                    continue;
                end

                deltaK = delta(k);
                currentR = rModel(k);

                k1 = nomoto_utils.nonLinearRhs(currentR, deltaK, K, T, alpha);
                k2 = nomoto_utils.nonLinearRhs(currentR + 0.5 * dt * k1, deltaK, K, T, alpha);
                k3 = nomoto_utils.nonLinearRhs(currentR + 0.5 * dt * k2, deltaK, K, T, alpha);
                k4 = nomoto_utils.nonLinearRhs(currentR + dt * k3, deltaK, K, T, alpha);

                rModel(k + 1) = currentR + (dt / 6) * (k1 + 2 * k2 + 2 * k3 + k4);
            end
        end

        function value = nonLinearRhs(r, delta, K, T, alpha)
            % nonLinearRhs
            % 非线性 Nomoto 模型右端函数。

            value = (K * delta - r - alpha * r.^3) / T;
        end

        function value = rmse(yTrue, yPred)
            % rmse
            % 均方根误差。

            yTrue = nomoto_utils.ensureColumn(yTrue);
            yPred = nomoto_utils.ensureColumn(yPred);
            value = sqrt(mean((yTrue - yPred).^2));
        end

        function value = rsquared(yTrue, yPred)
            % rsquared
            % 决定系数 R^2。

            yTrue = nomoto_utils.ensureColumn(yTrue);
            yPred = nomoto_utils.ensureColumn(yPred);

            ssRes = sum((yTrue - yPred).^2);
            ssTot = sum((yTrue - mean(yTrue)).^2);

            if ssTot <= eps
                value = 1;
            else
                value = 1 - ssRes / ssTot;
            end
        end

        function radValue = angleToRad(value, unitName)
            % angleToRad
            % 角度转弧度。

            unitName = lower(strtrim(char(string(unitName))));
            switch unitName
                case {'deg', 'degree', 'degrees', '°'}
                    radValue = value * pi / 180;
                case {'rad', 'radian', 'radians'}
                    radValue = value;
                otherwise
                    error('不支持的角度单位：%s', unitName);
            end
        end

        function radRate = rateToRad(value, unitName)
            % rateToRad
            % 角速度转 rad/s。

            unitName = lower(strtrim(char(string(unitName))));
            switch unitName
                case {'deg/s', 'degree/s', 'degrees/s', 'degps'}
                    radRate = value * pi / 180;
                case {'rad/s', 'radian/s', 'radians/s', 'radps'}
                    radRate = value;
                otherwise
                    error('不支持的角速度单位：%s', unitName);
            end
        end

        function value = angleFromRad(radValue, unitName)
            % angleFromRad
            % 弧度转指定角度单位。

            unitName = lower(strtrim(char(string(unitName))));
            switch unitName
                case {'deg', 'degree', 'degrees', '°'}
                    value = radValue * 180 / pi;
                case {'rad', 'radian', 'radians'}
                    value = radValue;
                otherwise
                    error('不支持的角度单位：%s', unitName);
            end
        end

        function value = rateFromRad(radValue, unitName)
            % rateFromRad
            % rad/s 转指定角速度单位。

            unitName = lower(strtrim(char(string(unitName))));
            switch unitName
                case {'deg/s', 'degree/s', 'degrees/s', 'degps'}
                    value = radValue * 180 / pi;
                case {'rad/s', 'radian/s', 'radians/s', 'radps'}
                    value = radValue;
                otherwise
                    error('不支持的角速度单位：%s', unitName);
            end
        end

        function labelText = angleUnitLabel(unitName)
            % angleUnitLabel
            % 返回用于图轴标注的角度单位。

            unitName = lower(strtrim(char(string(unitName))));
            switch unitName
                case {'deg', 'degree', 'degrees', '°'}
                    labelText = 'deg';
                case {'rad', 'radian', 'radians'}
                    labelText = 'rad';
                otherwise
                    labelText = char(string(unitName));
            end
        end

        function labelText = rateUnitLabel(unitName)
            % rateUnitLabel
            % 返回用于图轴标注的角速度单位。

            unitName = lower(strtrim(char(string(unitName))));
            switch unitName
                case {'deg/s', 'degree/s', 'degrees/s', 'degps'}
                    labelText = 'deg/s';
                case {'rad/s', 'radian/s', 'radians/s', 'radps'}
                    labelText = 'rad/s';
                otherwise
                    labelText = char(string(unitName));
            end
        end

        function style = thesisPlotStyle()
            % thesisPlotStyle
            % 返回适合毕业论文插图的统一绘图风格参数。

            style = struct();
            style.measuredColor = [0.20, 0.20, 0.20];
            style.inputColor = [0.27, 0.45, 0.77];
            style.linearColor = [0.27, 0.45, 0.77];
            style.pointColor = [74, 35, 120] / 255;
            style.fitColor = [0.82, 0.10, 0.10];
            style.segmentPatchColor = [0.90, 0.93, 0.98];
            style.lineWidth = 1.2;
            style.fitLineWidth = 1.5;
            style.pointSize = 32;
            style.axesLineWidth = 0.9;
            style.fontSize = 11;
        end

        function applyThesisAxesStyle(style)
            % applyThesisAxesStyle
            % 统一设置论文中常用的白底、网格、边框与字号风格。

            if nargin < 1 || isempty(style)
                style = nomoto_utils.thesisPlotStyle();
            end

            grid on;
            box on;
            ax = gca;
            ax.LineWidth = style.axesLineWidth;
            ax.FontSize = style.fontSize;
        end

        function x = ensureColumn(x)
            % ensureColumn
            % 保证输出为列向量。

            x = x(:);
        end

        function assertRequiredFields(cfg, fieldNames)
            % assertRequiredFields
            % 检查配置结构体中是否包含所需字段。

            for i = 1:numel(fieldNames)
                if ~isfield(cfg, fieldNames{i})
                    error('配置结构体缺少字段：%s', fieldNames{i});
                end
            end
        end
    end
end



