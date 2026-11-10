#!/bin/bash
#SBATCH --job-name=quantum
#SBATCH --output=/shared/user/%x-%j.out
#SBATCH --licenses=qpu@qc_gateway:2
echo "batch step: IQM_TOKEN=[${IQM_TOKEN:-<unset>}]"
echo "batch step: LICENSES=[${SLURM_JOB_LICENSES:-<unset>}]"
echo "batch step: node=$(hostname -s)"
srun bash -c "echo srun step: IQM_TOKEN=[\${IQM_TOKEN:-<unset>}] on \$(hostname -s)"
