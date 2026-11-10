#!/bin/bash
#SBATCH --job-name=arr
#SBATCH --output=/shared/user/%x-%A_%a.out
#SBATCH --licenses=qpu@qc_gateway:1
#SBATCH --array=0-2
echo "element $SLURM_ARRAY_TASK_ID job=$SLURM_JOB_ID node=$(hostname -s) token=[${IQM_TOKEN:-<unset>}]"
sleep 25
