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

The repository contains 4 codes
1. The main code is 
