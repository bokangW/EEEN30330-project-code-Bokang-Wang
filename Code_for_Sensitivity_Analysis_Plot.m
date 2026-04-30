clear; clc; close all;
dbstop if error

%% =======================
% Global formatting settings

axLW   = 1.8;
axFS   = 13;
lblFS  = 14;
ttlFS  = 15;
lgdFS  = 11;

%% =======================
% 0) Read CSV (15-min data)

csvFile = 'Jan 19 to 20 15 min.csv';
T = readtable(csvFile, 'NumHeaderLines', 21, 'VariableNamingRule', 'preserve');
V12 = double(T.("Wind spee"));

V12(~isfinite(V12)) = NaN;
V12(V12 < 0) = NaN;
V12 = fillmissing(V12, 'linear');

%% =======================
% 1) Wind shear to hub height

H1 = 12;  H2 = 125;  alpha = 0.3;
V125 = V12 .* (H2/H1).^alpha;

%% =======================
% 2) Wind turbine power curve

Pr  = 6.2;
Vci = 3;  Vr = 10.5;  Vco = 24;

Pwind = zeros(size(V125));
idx_ramp  = (V125 >= Vci) & (V125 < Vr);
idx_rated = (V125 >= Vr)  & (V125 < Vco);
Pwind(idx_ramp)  = Pr * ((V125(idx_ramp).^3 - Vci^3) ./ (Vr^3 - Vci^3));
Pwind(idx_rated) = Pr;
Pwind = Pwind(:);
N = numel(Pwind);

%% =======================
% 3) Common settings

dt = 0.25;
Ebatt_range = 0:1.5:15;
nE = numel(Ebatt_range);

Crate = 0.5;
efficiency_c = 0.95;
efficiency_d = 0.95;

SOCmin = 0.2;  SOCmax = 0.8;
SOClow = 0.4;  SOChigh = 0.6;
SOC0 = 0.5;

%% =======================
% 4) Baselines

dP_raw = diff(Pwind);
SD_base_out = std(dP_raw, 'omitnan');

%% ========================================================================
%  PART A: Export Limit Sensitivity  (MA_Window fixed = 6)

MA_Window_fixed = 6;
Plim_ratio_range = [0.95, 0.85, 0.75];
nR = numel(Plim_ratio_range);

SR_exp_all      = zeros(nE, nR);
Ramp95_exp_all  = zeros(nE, nR);
SD_exp_all      = zeros(nE, nR);

SR_nolim      = zeros(nE, 1);
Ramp95_nolim  = zeros(nE, 1);
SD_nolim      = zeros(nE, 1);

Ptarget_nolim = movmean(Pwind, [MA_Window_fixed-1, 0], 'omitnan');

for i = 1:nE
    Ebatt = Ebatt_range(i);
    Pcmax = Crate * Ebatt;
    Pdmax = Crate * Ebatt;

    % --- Baseline: BESS without export limit ---
    SOC_tmp = zeros(N,1); SOC_tmp(1) = SOC0;
    Pout_tmp = zeros(N,1);
    for t = 1:N
        if t == 1, soc_prev = SOC0; else, soc_prev = SOC_tmp(t-1); end
        Praw = Pwind(t) - Ptarget_nolim(t);
        if Praw > 0,     X = X_charge(soc_prev, SOChigh, SOCmax);
        elseif Praw < 0, X = X_disch(soc_prev, SOCmin, SOClow);
        else,            X = 0; end
        Pbatt_cmd = Praw * (1 - X^3);
        [Pbatt_act, SOC_tmp(t), ~, ~] = update_soc_physics( ...
            soc_prev, Pbatt_cmd, Ebatt, dt, ...
            efficiency_c, efficiency_d, SOCmin, SOCmax, Pcmax, Pdmax);
        Pout_tmp(t) = max(0, Pwind(t) - Pbatt_act);
    end
    dP_tmp = diff(Pout_tmp);
    SD_nolim(i)     = std(dP_tmp, 'omitnan');
    SR_nolim(i)     = 1 - SD_nolim(i) / max(SD_base_out, 1e-12);
    Ramp95_nolim(i) = quantile(abs(dP_tmp), 0.95);

    % --- Loop over export limit ratios ---
    for j = 1:nR
        Plim = Plim_ratio_range(j) * Pr;
        clamp_export = @(P) max(0, min(P, Plim));
        Pwind_capped = min(Pwind, Plim);
        Ptarget_exp = movmean(Pwind_capped, [MA_Window_fixed-1, 0], 'omitnan');

        SOC_tmp2 = zeros(N,1); SOC_tmp2(1) = SOC0;
        Pout2_raw = zeros(N,1);
        Pexp_tmp  = zeros(N,1);
        for t = 1:N
            if t == 1, soc_prev2 = SOC0; else, soc_prev2 = SOC_tmp2(t-1); end
            Praw2 = min(Pwind(t), Plim) - Ptarget_exp(t);
            if Praw2 > 0,     X2 = X_charge(soc_prev2, SOChigh, SOCmax);
            elseif Praw2 < 0, X2 = X_disch(soc_prev2, SOCmin, SOClow);
            else,             X2 = 0; end
            Pbatt_cmd2 = Praw2 * (1 - X2^3);
            [Pbatt_act2, SOC_tmp2(t), ~, ~] = update_soc_physics( ...
                soc_prev2, Pbatt_cmd2, Ebatt, dt, ...
                efficiency_c, efficiency_d, SOCmin, SOCmax, Pcmax, Pdmax);
            Pout2_raw(t) = max(0, Pwind(t) - Pbatt_act2);
            Pexp_tmp(t)  = clamp_export(Pout2_raw(t));
        end

        dP_exp = diff(Pexp_tmp);
        SD_exp_all(i,j) = std(dP_exp, 'omitnan');

        Ponly_clip = min(Pwind, Plim);
        dP_clip = diff(Ponly_clip);
        SD_clip = std(dP_clip, 'omitnan');
        SR_exp_all(i,j) = 1 - SD_exp_all(i,j) / max(SD_clip, 1e-12);

        Ramp95_exp_all(i,j) = quantile(abs(dP_exp), 0.95);

    end

    fprintf('[Part A] Ebatt = %5.1f MWh done\n', Ebatt);
end

%% ========================================================================
%  PART B: MA Window Sensitivity  (Plim_ratio fixed = 0.85)

Plim_ratio_fixed = 0.85;
Plim_fixed = Plim_ratio_fixed * Pr;
clamp_export_fixed = @(P) max(0, min(P, Plim_fixed));

MA_Window_range = [4, 6, 8];
nW = numel(MA_Window_range);

SR_ma_all      = zeros(nE, nW);
Ramp95_ma_all  = zeros(nE, nW);
SD_ma_all      = zeros(nE, nW);

% "Only clipping" baseline is the same for all MA windows (same Plim)
Ponly_clip_fixed = min(Pwind, Plim_fixed);
dP_clip_fixed = diff(Ponly_clip_fixed);
SD_clip_fixed = std(dP_clip_fixed, 'omitnan');

for i = 1:nE
    Ebatt = Ebatt_range(i);
    Pcmax = Crate * Ebatt;
    Pdmax = Crate * Ebatt;

    for w = 1:nW
        MA_W = MA_Window_range(w);

        Pwind_capped = min(Pwind, Plim_fixed);
        Ptarget_w = movmean(Pwind_capped, [MA_W-1, 0], 'omitnan');

        SOC_tmp3 = zeros(N,1); SOC_tmp3(1) = SOC0;
        Pout3_raw = zeros(N,1);
        Pexp3     = zeros(N,1);

        for t = 1:N
            if t == 1, soc_prev3 = SOC0; else, soc_prev3 = SOC_tmp3(t-1); end
            Praw3 = min(Pwind(t), Plim_fixed) - Ptarget_w(t);
            if Praw3 > 0,     X3 = X_charge(soc_prev3, SOChigh, SOCmax);
            elseif Praw3 < 0, X3 = X_disch(soc_prev3, SOCmin, SOClow);
            else,             X3 = 0; end
            Pbatt_cmd3 = Praw3 * (1 - X3^3);
            [Pbatt_act3, SOC_tmp3(t), ~, ~] = update_soc_physics( ...
                soc_prev3, Pbatt_cmd3, Ebatt, dt, ...
                efficiency_c, efficiency_d, SOCmin, SOCmax, Pcmax, Pdmax);
            Pout3_raw(t) = max(0, Pwind(t) - Pbatt_act3);
            Pexp3(t)     = clamp_export_fixed(Pout3_raw(t));
        end

        dP_ma = diff(Pexp3);
        SD_ma_all(i,w) = std(dP_ma, 'omitnan');
        SR_ma_all(i,w) = 1 - SD_ma_all(i,w) / max(SD_clip_fixed, 1e-12);
        Ramp95_ma_all(i,w) = quantile(abs(dP_ma), 0.95);

    end

    fprintf('[Part B] Ebatt = %5.1f MWh done\n', Ebatt);
end

%% ========================================================================
%  PLOTTING

mSize = 5;

% ===================== Export Limit Figures =====================
colors_A = lines(nR + 1);
labels_lim = arrayfun(@(r) sprintf('%.2fP_r', r), Plim_ratio_range, 'UniformOutput', false);
labels_A = ['Unconstrained', labels_lim];

% (a) SR — Export Limit
figure('Color','w','Position',[100 100 700 500]);
plot(Ebatt_range, SR_nolim, '-o', 'Color', colors_A(1,:), ...
    'LineWidth', 2, 'MarkerSize', mSize, 'MarkerFaceColor', colors_A(1,:)); hold on;
for j = 1:nR
    plot(Ebatt_range, SR_exp_all(:,j), '-o', 'Color', colors_A(j+1,:), ...
        'LineWidth', 2, 'MarkerSize', mSize, 'MarkerFaceColor', colors_A(j+1,:));
end
grid on;
xlabel('Battery Capacity (MWh)', 'FontSize', lblFS, 'FontWeight', 'bold');
ylabel('Smoothing Rate, SR', 'FontSize', lblFS, 'FontWeight', 'bold');
title('Smoothing Rate vs Battery Capacity (Export Limit Sensitivity)', ...
    'FontSize', ttlFS, 'FontWeight', 'bold');
legend(labels_A, 'Location', 'best', 'FontSize', lgdFS);
set(gca, 'LineWidth', axLW, 'FontSize', axFS, 'FontWeight', 'bold');

% (b) 95th Ramp — Export Limit
figure('Color','w','Position',[120 120 700 500]);
plot(Ebatt_range, Ramp95_nolim, '-o', 'Color', colors_A(1,:), ...
    'LineWidth', 2, 'MarkerSize', mSize, 'MarkerFaceColor', colors_A(1,:)); hold on;
for j = 1:nR
    plot(Ebatt_range, Ramp95_exp_all(:,j), '-o', 'Color', colors_A(j+1,:), ...
        'LineWidth', 2, 'MarkerSize', mSize, 'MarkerFaceColor', colors_A(j+1,:));
end
yline(0.93, '--k', 'LineWidth', 1.8, 'HandleVisibility', 'off');
text(max(Ebatt_range)*0.98, 0.93 + 0.03, 'Ramp limit = 0.93 MW', ...
    'FontSize', 10, 'FontWeight', 'bold', 'HorizontalAlignment', 'right', ...
    'Color', [0.15 0.15 0.15]);
grid on;
xlabel('Battery Capacity (MWh)', 'FontSize', lblFS, 'FontWeight', 'bold');
ylabel('95th Percentile |\DeltaP| (MW/15 min)', 'FontSize', lblFS, 'FontWeight', 'bold');
title('95th-Percentile Ramp vs Battery Capacity (Export Limit Sensitivity)', ...
    'FontSize', ttlFS, 'FontWeight', 'bold');
legend(labels_A, 'Location', 'best', 'FontSize', lgdFS);
set(gca, 'LineWidth', axLW, 'FontSize', axFS, 'FontWeight', 'bold');

% ===================== MA Window Figures =====================
colors_B = lines(nW);
labels_B = {'W = 4 (1.0 h)', 'W = 6 (1.5 h)', 'W = 8 (2.0 h)'};

% (c) SR — MA Window
figure('Color','w','Position',[140 140 700 500]);
for w = 1:nW
    plot(Ebatt_range, SR_ma_all(:,w), '-o', 'Color', colors_B(w,:), ...
        'LineWidth', 2, 'MarkerSize', mSize, 'MarkerFaceColor', colors_B(w,:)); hold on;
end
grid on;
xlabel('Battery Capacity (MWh)', 'FontSize', lblFS, 'FontWeight', 'bold');
ylabel('Smoothing Rate, SR', 'FontSize', lblFS, 'FontWeight', 'bold');
title(sprintf('Smoothing Rate vs Battery Capacity (MA Window Sensitivity, %.2fP_r)', ...
    Plim_ratio_fixed), 'FontSize', ttlFS, 'FontWeight', 'bold');
legend(labels_B, 'Location', 'best', 'FontSize', lgdFS);
set(gca, 'LineWidth', axLW, 'FontSize', axFS, 'FontWeight', 'bold');

% (d) 95th Ramp — MA Window
figure('Color','w','Position',[160 160 700 500]);
for w = 1:nW
    plot(Ebatt_range, Ramp95_ma_all(:,w), '-o', 'Color', colors_B(w,:), ...
        'LineWidth', 2, 'MarkerSize', mSize, 'MarkerFaceColor', colors_B(w,:)); hold on;
end
yline(0.93, '--k', 'LineWidth', 1.8, 'HandleVisibility', 'off');
text(max(Ebatt_range)*0.98, 0.93 + 0.03, 'Ramp limit = 0.93 MW', ...
    'FontSize', 10, 'FontWeight', 'bold', 'HorizontalAlignment', 'right', ...
    'Color', [0.15 0.15 0.15]);
grid on;
xlabel('Battery Capacity (MWh)', 'FontSize', lblFS, 'FontWeight', 'bold');
ylabel('95th Percentile |\DeltaP| (MW/15 min)', 'FontSize', lblFS, 'FontWeight', 'bold');
title(sprintf('95th-Percentile Ramp vs Battery Capacity (MA Window Sensitivity, %.2fP_r)', ...
    Plim_ratio_fixed), 'FontSize', ttlFS, 'FontWeight', 'bold');
legend(labels_B, 'Location', 'best', 'FontSize', lgdFS);
set(gca, 'LineWidth', axLW, 'FontSize', axFS, 'FontWeight', 'bold');


%% ========================================================================
% Local functions

function X = X_charge(SOC, SOChigh, SOCmax)
    if SOC <= SOChigh, X = 0;
    elseif SOC >= SOCmax, X = 1;
    else, X = (SOC - SOChigh) / (SOCmax - SOChigh);
    end
end

function X = X_disch(SOC, SOCmin, SOClow)
    if SOC >= SOClow, X = 0;
    elseif SOC <= SOCmin, X = 1;
    else, X = (SOClow - SOC) / (SOClow - SOCmin);
    end
end

function [Pbatt_exec, SOC_new, Pch_feas, Pdis_feas] = update_soc_physics( ...
    SOC_prev, Pbatt_cmd, Ebatt_MWh, dt_h, efficiency_c, efficiency_d, ...
    SOCmin, SOCmax, Pcmax, Pdmax)

    if Ebatt_MWh == 0
        Pbatt_exec = 0; SOC_new = SOC_prev;
        Pch_feas = 0; Pdis_feas = 0;
        return;
    end

    Pch_feas = min(Pcmax, (SOCmax - SOC_prev) * Ebatt_MWh / (efficiency_c * dt_h));
    Pdis_feas = min(Pdmax, (SOC_prev - SOCmin) * efficiency_d * Ebatt_MWh / dt_h);
    Pbatt_exec = min(max(Pbatt_cmd, -Pdis_feas), Pch_feas);

    if Pbatt_exec >= 0
        SOC_new = SOC_prev + (Pbatt_exec * efficiency_c * dt_h) / Ebatt_MWh;
    else
        SOC_new = SOC_prev - ((-Pbatt_exec) / efficiency_d * dt_h) / Ebatt_MWh;
    end
    SOC_new = min(max(SOC_new, SOCmin), SOCmax);
end