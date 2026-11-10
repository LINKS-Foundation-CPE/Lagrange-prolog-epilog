#!/bin/bash
#SBATCH --job-name=classical
#SBATCH --output=/shared/user/%x-%j.out
echo "IQM_TOKEN=[${IQM_TOKEN:-<unset>}]"
echo "LICENSES=[${SLURM_JOB_LICENSES:-<unset>}]"
