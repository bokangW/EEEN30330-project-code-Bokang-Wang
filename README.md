# Eeen30330-project-code-Bokang-Wang
# Title 
Battery Storage Capacity Sizing for Wind Power Smoothing under Export Constraints: A Leeds-Based UK Onshore Wind Case Study

# Introduction
This repository contains the MATLAB code developed for my EEEN30330 Individual 3rd Year Project:Battery Storage Capacity Sizing for Wind Power Smoothing under Export Constraints: A Leeds-Based UK Onshore Wind Case Study. The project investigates the technical and economic performance of a battery energy storage system (BESS) for smoothing onshore wind power under distribution network operator (DNO) export constraints. The case study is based on 15-minute wind speed data for Leeds, UK. The MATLAB code is used to model wind turbine power output, apply BESS smoothing control, evaluate different battery capacities, compare unconstrained and export-constrained cases, and generate selected figures used in the final report.

# Contextual Overview
The model follows the workflow below:
1. Process 15-minute wind speed data for the Leeds case study.
2. Convert wind speed to turbine output power using the Vestas V162-6.2 MW power curve.
3. Apply a moving-average-based BESS smoothing control strategy with SOC and power constraints.
4. Compare cases with and without export constraints.
5. Evaluate smoothing performance using 95th-percentile 15-minute ramp metric and smoothing rate.
6. Evaluate economic performance usaing NPV
7. Carry out sensitivity analysis for export limits, moving average window sizes, and ramp-rate limits.
8. Generate plots used to support the results and discussion in the final report.

The repository includes 4 codes
1. The Main_Code.m is for the wind–BESS model which adding clipping inside the moving average target. It runs the core technical and economic analysis for different battery capacities under unconstrained and export-constrained cases.
2. The Clipping_at_Output_Only_Code.m is the comparison case where export clipping is applied only at the final output stage. This was used to investigate whether the ramp-distribution reshaping was caused by including clipping inside the moving average target.
3. Code_for_Sensitivity_Analysis_Plot.m is the Code for generating the sensitivity analysis figures, including the effect of different export constraints and moving average window sizes.
4. Code_for_Power_Wind_Speed_Curve_Plot.m is the code for constructing and plotting the power–wind speed curve for the Vestas V162-6.2 MW wind turbine.

# Installation Instructions
Required Software: 
MATLAB R2025b or later versions.

Required Libraries or Toolboxes:
No additional third-party libraries are required.
No additional MATLAB toolboxes are required.

Environment Setup
1. Download this GitHub repository.
2. Open MATLAB.
3. Set the MATLAB current folder to the repository folder.
4. Ensure all `.m` files are in the same folder, or update the file paths in the scripts if folders are used.

# How to Run the Software
Open MATLAB and set the current folder to this repository

To run the main wind–BESS model, use: The Main_Code.m
To run the comparison case where export clipping is applied only at the final output stage, use: The Clipping_at_Output_Only_Code.m
To generate the Vestas V162-6.2 MW power–wind speed curve, use: Code_for_Power_Wind_Speed_Curve_Plot.m
To generate the sensitivity analysis figures, use: Code_for_Sensitivity_Analysis_Plot.m

# Technical Details
1. Wind Speed Processing:
The project uses 15-minute wind speed data for the Leeds case study. Wind speed is adjusted to turbine hub height using a power-law wind shear model.
You can find the wind speed data "01/01/2019 - 01/01/2020 15 min readings" from https://ckan.publishing.service.gov.uk/dataset/leeds-meteorological-data

2. Wind Turbine Model:
The turbine output power is calculated using a segmented power–wind speed curve. The model is based on the Vestas V162-6.2 MW turbine.

3. BESS Model:
The battery energy storage system is modelled using:
Battery capacity range from 0 MWh to 15 MWh
SOC update equations
Charging and discharging efficiency
Minimum and maximum SOC limits
Nonlinear attenuation mechanism based on SOC 
C-rate-based power limits
No grid charging assumption

5. Smoothing Control Strategy:
The BESS smoothing control is based on a simple moving average target. The battery charges or discharges to reduce short-term wind power fluctuations, subject to SOC and power constraints.

Two main operating cases are compared:
First, unconstrained case, where no export limit is applied.
Second, export-constrained case, where output power is limited by export constraint, and the export constraint is adding on the moving average target.
An additional output-only clipping case is included to test whether ramp-distribution reshaping is caused by including export clipping inside the moving average target.

6. Technical Performance Metrics:
The code calculates ramp-based technical indicators, including:
- Ramp standard deviation
- Smoothing rate
- 95th-percentile ramp metric
- 99th-percentile ramp metric

7. Economic Evaluation:
The main model includes a simplified NPV calculation to compare the economic performance of battery capacities under the assumed cost and revenue conditions.

8. Sensitivity Analysis for the code:
-Export limit
-Moving average window size

# Known Issues and Future Improvements
- The analysis is based on one representative year of wind speed data.
- The model uses 15-minute resolution data, which may not capture very short-term wind power fluctuations.
- The wind turbine is modelled using a simplified power curve rather than a detailed aerodynamic model.
- Battery ageing, degradation, and capacity fade are not modelled in detail.
- The economic model uses a simplified revenue structure and does not include balancing market or ancillary service revenues.
- The results depend on assumptions such as the export limit, moving average window size, SOC limits, C-rate, and battery cost.

# Future Improvements
- Using multi-year wind speed datasets.
- Using higher temporal resolution wind data.
- Including a more detailed battery degradation model.
- Testing more advanced control strategies, such as model predictive control.
- Including real-time electricity prices and additional market revenue streams.
- Performing further sensitivity analysis on battery cost, C-rate, SOC limits, and battery lifetime.

# Third-Party Code and References
All MATLAB code in this repository was written by the project author unless otherwise stated.
No third-party code was directly reused.
MATLAB built-in functions were used for numerical calculation, data processing, and plotting. The modelling assumptions, equations, turbine parameters, data sources, and academic references are documented in the final report.
