#!/bin/bash
#SBATCH --job-name=multinode
#SBATCH --output=/shared/user/%x-%j.out
#SBATCH --licenses=qpu@qc_gateway:2
#SBATCH --nodes=2
#SBATCH --ntasks=2
#SBATCH --ntasks-per-node=1
echo "batch step on $(hostname -s): token=[${IQM_TOKEN:-<unset>}]"
srun bash -c "echo srun task on \$(hostname -s): token=[\${IQM_TOKEN:-<unset>}]"
echo "srun exit status: $?"
