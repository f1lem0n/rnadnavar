//
// Consensus
//
// For all modules here:
// A when clause condition is defined in the conf/modules.config to determine if the module should be run
include { VCF2MAF                                  } from '../../../modules/local/vcf2maf/vcf2maf/main'
include { RUN_CONSENSUS                            } from '../../../modules/local/consensus/main'
include { RUN_CONSENSUS as RUN_CONSENSUS_RESCUE    } from '../../../modules/local/consensus/main'
// Create samplesheets to restart from consensus
include { CHANNEL_CONSENSUS_CREATE_CSV                 } from '../channel_consensus_create_csv/main'
include { CHANNEL_CONSENSUS_CREATE_CSV as CHANNEL_RESCUE_CREATE_CSV                 } from '../channel_consensus_create_csv/main'

workflow VCF_CONSENSUS {
    take:
    tools
    vcf_to_consensus
    fasta
    previous_maf_consensus_dna  // results already done to avoid a second run when rna filterig
    previous_mafs_status_dna    // results already done to avoid a second run when rna filterig
    input_sample
    realignment

    main:
    versions                = Channel.empty()

    maf_from_consensus_dna  = Channel.empty()
    mafs_from_varcal_dna    = Channel.empty()
    consensus_maf           = Channel.empty()

    if (params.step == 'consensus') vcf_to_consensus = input_sample


    if ((params.step in ['mapping', 'markduplicates', 'splitncigar',
                        'prepare_recalibration', 'recalibrate', 'variant_calling', 'annotate',
                        'normalise', 'consensus'] &&
                        ((params.tools && params.tools.split(",").contains("consensus")))) ||
                        realignment) {

        vcf_to_consensus_type = vcf_to_consensus.branch{
                                vcf: it[0].data_type == "vcf"
                                maf: it[0].data_type == "maf"
                                }
        // First we transform the maf to MAF
        VCF2MAF(vcf_to_consensus_type.vcf.map{metaVCF -> [metaVCF[0], metaVCF[1]]},
                fasta)
        maf_to_consensus = VCF2MAF.out.maf.mix(vcf_to_consensus_type.maf)
        versions         = versions.mix(VCF2MAF.out.versions)

//        maf_to_consensus.dump(tag:"maf_to_consensus")
        // count number of callers to generate groupKey
        if (realignment) tools = "sage,strelka,mutect2"
        maf_to_consensus.dump(tag:"maf_to_consensus0")
        maf_to_consensus = maf_to_consensus.map{ meta, maf ->
                                    def toolsllist = tools.split(',')
                                    def ncallers   = toolsllist.count('sage') +
                                                    toolsllist.count('strelka') +
                                                    toolsllist.count('mutect2')
                                    key = groupKey(meta.subMap('id', 'patient', 'status') +
                                                [ncallers : ncallers], ncallers)
                                    [key, maf, meta.variantcaller]}
                                    .groupTuple()
        maf_to_consensus.dump(tag:"maf_to_consensus1")
        // Run consensus on VCF with same id
        RUN_CONSENSUS ( maf_to_consensus )

        consensus_maf = RUN_CONSENSUS.out.maf  // 1 consensus_maf from all callers
        // Separate DNA from RNA
        // VCFs from variant calling
        mafs_from_varcal   = maf_to_consensus.branch{
                                dna: it[0].status <= 1
                                rna: it[0].status == 2
                                }
        // VCF from consensus
        maf_from_consensus = consensus_maf.branch{
                                dna: it[0].status <= 1
                                rna: it[0].status == 2
                                }

        maf_from_consensus_rna = maf_from_consensus.rna.map{meta, maf -> [meta, maf, ['ConsensusRNA']]}
        mafs_from_varcal_rna   = mafs_from_varcal.rna

        // Only RNA mafs are processed again if second run
        if (previous_maf_consensus_dna && ((params.tools && params.tools.split(',').contains('realignment')))){
            maf_from_consensus_dna = previous_maf_consensus_dna   // VCF with consensus calling
            mafs_from_varcal_dna   = previous_mafs_status_dna     // VCFs with consensus calling
        } else {
            maf_from_consensus_dna = maf_from_consensus.dna.map{meta, maf -> [meta, maf, ['ConsensusDNA']]}
            mafs_from_varcal_dna   = mafs_from_varcal.dna
        }

        CHANNEL_CONSENSUS_CREATE_CSV(
                                        maf_from_consensus_dna
                                        .mix(maf_from_consensus_rna)
                                        .mix(mafs_from_varcal_dna)
                                        .mix(mafs_from_varcal_rna)
                                        .transpose(),
                                        "consensus"
                                        )

        // RESCUE STEP: cross dna / rna for a crossed second consensus
        if (params.tools && params.tools.split(',').contains('rescue')) {
            // VCF from consensus
            maf_consensus_status_dna_to_cross = maf_from_consensus_dna.map{
                                                    meta, maf, caller ->
                                                    [meta.patient, meta, [maf], caller]
                                                    }

            maf_consensus_status_rna_to_cross = maf_from_consensus_rna.map{
                                                    meta, maf, caller ->
                                                    [meta.patient, meta, [maf], caller]
                                                    }
            // VCFs from variant calling
            mafs_status_dna_to_cross = mafs_from_varcal_dna.map{
                                                    meta, mafs, callers ->
                                                    [meta.patient, meta, mafs, callers]
                                                    }

            mafs_status_rna_to_cross = mafs_from_varcal_rna.map{
                                                    meta, mafs, callers ->
                                                    [meta.patient, meta, mafs, callers]
                                                    }

            // cross results keeping metadata // TODO make the id somehow shorter (atm is tumor_vs_normal_with_tumor_vs_normal -- too long)
            mafs_dna_crossed_with_rna_rescue = mafs_status_dna_to_cross
                                                .cross(maf_consensus_status_rna_to_cross)
                                                .map { dna, rna ->
                                                def meta = [:]
                                                meta.patient = dna[0]
                                                meta.dna_id  = dna[1].id
                                                meta.rna_id  = rna[1].id
                                                meta.status  = dna[1].status
                                                meta.id      = "${meta.dna_id}_with_${meta.rna_id}".toString()
                                                [meta, dna[2] + rna[2], dna[3] + rna[3]]
                                            }
            mafs_rna_crossed_with_dna_rescue = mafs_status_rna_to_cross
                                                .cross(maf_consensus_status_dna_to_cross)
                                                .map { rna, dna ->
                                                def meta = [:]
                                                meta.patient = rna[0]
                                                meta.rna_id  = rna[1].id
                                                meta.dna_id  = dna[1].id
                                                meta.status  = rna[1].status
                                                meta.id      = "${meta.rna_id}_with_${meta.dna_id}".toString()
                                                [meta, rna[2] + dna[2], rna[3] + dna[3]]
                                            }

            mafs_dna_crossed_with_rna_rescue.mix(mafs_rna_crossed_with_dna_rescue).dump(tag:"mafs_to_rescue")
            RUN_CONSENSUS_RESCUE ( mafs_dna_crossed_with_rna_rescue.mix(mafs_rna_crossed_with_dna_rescue) )

            maf_from_rescue = RUN_CONSENSUS_RESCUE.out.maf.branch{
                                dna: it[0].status <= 1
                                rna: it[0].status == 2
                                }

            maf_from_consensus_dna = maf_from_rescue.dna.map{meta, maf -> [meta, maf, ['ConsensusDNA']]}
            maf_from_consensus_rna = maf_from_rescue.rna.map{meta, maf -> [meta, maf, ['ConsensusRNA']]}
            consensus_maf = maf_from_consensus_dna.mix(maf_from_consensus_rna)
            maf_from_consensus_dna
                                        .mix(maf_from_consensus_rna)
                                        .mix(mafs_from_varcal_dna)
                                        .mix(mafs_from_varcal_rna).transpose().dump(tag:'rescued')
            CHANNEL_RESCUE_CREATE_CSV(
                                        maf_from_consensus_dna
                                        .mix(maf_from_consensus_rna)
                                        .mix(mafs_from_varcal_dna)
                                        .mix(mafs_from_varcal_rna)
                                        .transpose(),
                                        "rescued"
                                        )
        }
    } else {

        if (params.tools && (params.tools.split(",").contains('filtering') || params.tools.split(",").contains('rna_filtering') )){
            vcf_to_consensus_type = vcf_to_consensus.branch{
                                vcf: it[0].data_type == "vcf"
                                maf: it[0].data_type == "maf"
                                }
            // First we transform the maf to MAF
            VCF2MAF(vcf_to_consensus_type.vcf.map{metaVCF -> [metaVCF[0], metaVCF[1]]},
                    fasta)
            consensus_maf    = VCF2MAF.out.maf.mix(vcf_to_consensus_type.maf)
            versions         = versions.mix(VCF2MAF.out.versions)

        }


    }

    emit:
    maf_consensus_dna   = maf_from_consensus_dna
    mafs_dna            = mafs_from_varcal_dna
    maf                 = consensus_maf // channel: [ [meta], maf ]
    versions            = versions // channel: [ versions.yml ]
}
