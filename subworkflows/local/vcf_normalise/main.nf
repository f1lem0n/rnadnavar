//
// Normalise VCFs with VT
//
// For all modules here:
// A when clause condition is defined in the conf/modules.config to determine if the module should be run
// VT steps
include { VT_DECOMPOSE                        } from '../../../modules/local/vt/decompose/main'
include { VT_NORMALISE                        } from '../../../modules/local/vt/normalise/main'
// Create samplesheet to restart from different steps
include { CHANNEL_VARIANT_CALLING_CREATE_CSV  } from '../channel_variant_calling_create_csv/main'


workflow VCF_NORMALISE {
    take:
    vcf_to_normalise
    fasta
    input_sample
    realignment

    main:
    version          = Channel.empty()

    if (params.step == 'norm') vcf_to_normalise = input_sample

    if ((params.step in ['mapping', 'markduplicates', 'splitncigar',
                        'prepare_recalibration', 'recalibrate',
                        'variant_calling', 'norm'] &&
                        ((params.tools && params.tools.split(",").contains("consensus")))) ||
                        realignment) {

        vcf_decomposed  = Channel.empty()
        // Separate variants
        VT_DECOMPOSE(vcf_to_normalise)

        vcf_decomposed = vcf_decomposed.mix(VT_DECOMPOSE.out.vcf)
        version = version.mix(VT_DECOMPOSE.out.versions.first())

        // Normalise variants
        VT_NORMALISE(vcf_decomposed,
                    fasta)

        vcf_to_consensus = VT_NORMALISE.out.vcf
        version = version.mix(VT_NORMALISE.out.versions.first())

        CHANNEL_VARIANT_CALLING_CREATE_CSV(vcf_to_consensus, "normalised")

    } else {
        vcf_to_consensus = vcf_to_normalise
    }

    emit:
    vcf         = vcf_to_consensus // channel: [ [meta], vcf ]
    versions    = version // channel: [ versions.yml ]

}
