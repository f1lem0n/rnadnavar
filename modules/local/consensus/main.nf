process RUN_CONSENSUS {
    tag "$meta.id"
    label 'process_low'

    conda "bioconda::bioconductor-rtracklayer bioconda::bioconductor-complexheatmap conda-forge::r-ggrepel conda-forge::r-data.table conda-forge::r-dplyr conda-forge::ggpubr"
    container 'ghcr.io/raqmanzano/renv:latest'

    input:
        tuple val(meta), path(input_file, stageAs: "inputs/*"), val(caller), path(intervals)

    output:
        tuple val(meta), path('*.consensus.vcf')                , optional:true , emit: vcf
        tuple val(meta), path('*.consensus_*.vcf'), val(caller) , optional:true , emit: vcf_separate
        tuple val(meta), path('*.consensus.maf')                , optional:true , emit: maf
        tuple val(meta), path('*.consensus_*.maf'), val(caller) , optional:true , emit: maf_separate
        path("*.pdf")                                           , optional:true , emit: pdf
        path "versions.yml"                                                     , emit: versions

    when:
        task.ext.when == null || task.ext.when

    script:
        def args = task.ext.args ?: ''
        def prefix = task.ext.prefix ?: "${meta.id}"

        """
        if [ -n "${intervals}" ]; then
            INTER=\$(awk '{print \$1 ":" \$2 "-" \$3}' ${intervals})
            interval="--interval=\$INTER"
        else
            interval=""
        fi

        run_consensus.R --input_dir=inputs/ --out_prefix=${prefix}.consensus --cpu=$task.cpus $args \$interval

        cat <<-END_VERSIONS > versions.yml
        "${task.process}":
            R: \$(echo \$(R --version 2>&1) | head -n 1)
        END_VERSIONS
        """
}
