#!/usr/bin/env Rscript
suppressPackageStartupMessages({
    library(facetsSuite)
    library(argparse)
    library(dplyr)
    library(ggplot2)
    library(egg)
    library(purrr)
    library(tibble)
})

args = commandArgs(TRUE)
if (length(args) == 0) {
    message('Run run-facets-wrapper.R --help for list of input arguments.')
    quit()
}

parser = ArgumentParser(description = 'Run FACETS and associated output, input SNP read counts from snp-pileup.')

parser$add_argument('-v', '--verbose', action="store_true", default = TRUE,
                    help = 'Print run info')
parser$add_argument('-f', '--counts-file', required = TRUE,
                    help = 'Merged, gzipped tumor-normal output from snp-pileup')
parser$add_argument('-s', '--sample-id', required = FALSE,
                    help = 'Sample ID, preferrable Tumor_Normal to keep track of the normal used')
parser$add_argument('-D', '--directory', required = TRUE,
                    help = 'Output directory to which all output files are written to')
parser$add_argument('-e', '--everything', dest = 'everything', action = 'store_true',
                    default = FALSE, help = 'Run full suite [default %(default)s]')
parser$add_argument('-g', '--genome', required = FALSE,
                    choices = c('hg18', 'hg19', 'hg38'),
                    default = 'hg19', help = 'Reference genome [default %(default)s]')
parser$add_argument('-c', '--cval', required = FALSE, type = 'integer',
                    default = 50, help = 'Segmentation parameter (cval) [default %(default)s]')
parser$add_argument('-pc', '--purity-cval', required = FALSE, type = 'integer',
                    default = 100, help = 'If two pass, purity segmentation parameter (cval)')
parser$add_argument('-m', '--min-nhet', required = FALSE, type = 'integer',
                    default = 15, help = 'Min. number of heterozygous SNPs required for clustering [default %(default)s]')
parser$add_argument('-pm', '--purity-min-nhet', required = FALSE, type = 'integer',
                    default = 15, help = 'If two pass, purity min. number of heterozygous SNPs (cval) [default %(default)s]')
parser$add_argument('-n', '--snp-window-size', required = FALSE, type = 'integer', 
                    default = 250, help = 'Window size for heterozygous SNPs [default %(default)s]')
parser$add_argument('-nd', '--normal-depth', required = FALSE, type = 'integer',
                    default = 35, help = 'Min. depth in normal to keep SNPs [default %(default)s]')
parser$add_argument('-d', '--dipLogR', required = FALSE, type = 'double',
                    default = NULL, help = 'Manual dipLogR')
parser$add_argument('-S', '--seed', required = FALSE, type = 'integer',
                    default = 100, help = 'Manual seed value [default %(default)s]')
parser$add_argument('-l', '--legacy-output', required = FALSE, type = 'logical',
                    default = FALSE, help = 'create legacy output files (.RData and .cncf.txt) [default %(default)s]')
parser$add_argument('-fl', '--facets-lib-path', required = TRUE,
                    default = '', help = 'path to the facets library. if none provided, uses version available to `library(facets)`')

args = parser$parse_args()

# Helper functions ------------------------------------------------------------------------------------------------

# Write out
write = function(input, output) {
    write.table(input, file = output, quote = FALSE, sep = '\t', row.names = FALSE, col.names = TRUE)
}

# Print run details
print_run_details = function(outfile,
                             run_type,
                             cval,
                             min_nhet,
                             purity,
                             ploidy,
                             dipLogR,
                             flags = NULL,
                             ...) {
    params = c(...)
    
    run_details = data.frame(
        'sample' = sample_id,
        'run_type' = run_type,
        'purity' = signif(purity, 2),
        'ploidy' = signif(ploidy, 2),
        'dipLogR' = signif(dipLogR, 2),
        'facets_version' = as.character(packageVersion('facets')),
        'cval' = cval,
        'snp_nbhd' = args$snp_window_size,
        'min_nhet' = min_nhet,
        'ndepth' = args$normal_depth,
        'genome' = args$genome,
        'seed' = args$seed,
        'flags' = flags,
        'input_file' = basename(args$counts_file))
    
    if (length(params) > 0) {
        run_details = data.frame(run_details,
                                 'genome_doubled' = params$genome_doubled,
                                 'fraction_cna' = signif(as.numeric(params$fraction_cna), 2),
                                 'hypoploid' = params$hypoploid,
                                 'fraction_loh' = signif(as.numeric(params$fraction_loh), 2),
                                 'lst' = params$lst,
                                 'ntai' = params$ntelomeric_ai,
                                 'hrd_loh' = params$hrd_loh)
    }
    
    write(run_details, outfile)
    
    run_details
}

# Default set of output plots
print_plots = function(outfile,
                       facets_output,
                       cval) {
    
    plot_title = paste0(sample_id,
                        ' | cval=', cval,
                        ' | purity=', round(facets_output$purity, 2),
                        ' | ploidy=', round(facets_output$ploidy, 2),
                        ' | dipLogR=', round(facets_output$dipLogR, 2))
    
    png(file = outfile, width = 850, height = 999, units = 'px', type = 'cairo-png', res = 96)
    suppressWarnings(
        egg::ggarrange(
            plots = list(
                cnlr_plot(facets_output),
                valor_plot(facets_output),
                icn_plot(facets_output, method = 'em'),
                cf_plot(facets_output, method = 'em'),
                icn_plot(facets_output, method = 'cncf'),
                cf_plot(facets_output, method = 'cncf')
            ),
            ncol = 1,
            nrow = 6,
            heights = c(1, 1, 1, .15, 1, .15),
            top = plot_title)
    )
    dev.off()
}

# Print segmentation
print_segments = function(outfile,
                          facets_output) {
    write(facets_output$segs, outfile)
}

# Print IGV-style .seg file
print_igv = function(outfile,
                     facets_output,
		     doAdjust) {
    
    ii = format_igv_seg(facets_output = facets_output,
                        sample_id = sample_id,
                        normalize = doAdjust)
    
    write(ii, outfile)
}

# Define facets iteration
# Given a set of parameters, do:
# 1. Run facets
# 2. Generate and save plots
# 3. Print run iformation, IGV-style seg file, segmentation data
facets_iteration = function(name_prefix, ...) {
    params = list(...)
    
    output = run_facets(read_counts = read_counts,
                        cval = params$cval,
                        dipLogR = params$dipLogR,
                        ndepth = params$ndepth,
                        snp_nbhd = params$snp_nbhd,
                        min_nhet = params$min_nhet,
                        genome = params$genome,
                        seed = params$seed,
                        facets_lib_path = params$facets_lib_path)
    
    # No need to print the segmentation
    # print_segments(outfile = paste0(name_prefix, '.cncf.txt'), 
    #                facets_output = output)
    
    #We want to print both a dipLogR adjusted version and an unadjusted version.
    print_igv(outfile = paste0(name_prefix, '_diplogR.adjusted.seg'),
              facets_output = output, doAdjust=T)

    print_igv(outfile = paste0(name_prefix, '_diplogR.unadjusted.seg'),
              facets_output = output, doAdjust=F)
    
    print_plots(outfile = paste0(name_prefix, '.png'),
                facets_output = output,
                cval = params$cval)
    
    output
}

# Run -------------------------------------------------------------------------------------------------------------

# Name files and create output directory
sample_id = ifelse(is.na(args$sample_id),
                   gsub('(.dat.gz$|.gz$)', '', basename(args$counts_file)),
                   args$sample_id)
directory = args$directory

if (dir.exists(directory)) {
    #stop('Output directory already exists, specify a different one.',  call. = F)
} else {
    system(paste('mkdir -p', directory))
}

# Read SNP counts file
message(paste('Reading', args$counts_file))
read_counts = facets::readSnpMatrix(args$counts_file)
message(paste('Writing to', directory))

# Determine if running two-pass
if (!is.null(args$purity_cval)) {
    name = paste0(directory, '/', sample_id)
    purity_output = facets_iteration(name_prefix = paste0(name, '_purity'),
                                     dipLogR = args$dipLogR,
                                     cval = args$purity_cval,
                                     ndepth = args$normal_depth,
                                     snp_nbhd = args$snp_window_size,
                                     min_nhet = args$purity_min_nhet,
                                     genome = args$genome,
                                     seed = args$seed,
                                     facets_lib_path = args$facets_lib_path)

    hisens_output = facets_iteration(name_prefix = paste0(name, '_hisens'),
                                     dipLogR = purity_output$dipLogR,
                                     cval = args$cval,
                                     ndepth = args$normal_depth,
                                     snp_nbhd = args$snp_window_size,
                                     min_nhet = args$min_nhet,
                                     genome = args$genome,
                                     seed = args$seed,
                                     facets_lib_path = args$facets_lib_path)
    
    metadata = NULL
    if (args$everything) {
        metadata = c(
            map_dfr(list(purity_output, hisens_output), function(x) { arm_level_changes(x$segs, x$ploidy, args$genome)[-5] }),
            map_dfr(list(purity_output, hisens_output), function(x) calculate_lst(x$segs, x$ploidy, args$genome)),
            map_dfr(list(purity_output, hisens_output), function(x) calculate_ntai(x$segs, x$ploidy, args$genome)),
            map_dfr(list(purity_output, hisens_output), function(x) calculate_hrdloh(x$segs, x$ploidy)),
            map_dfr(list(purity_output, hisens_output), function(x) calculate_loh(x$segs, x$snps, args$genome))
        )
        
        qc = map_dfr(list(purity_output, hisens_output), function(x) check_fit(x, genome = args$genome)) %>% 
            add_column(sample = sample_id,
                       cval = c(args$purity_cval, args$cval), .before = 1)
        # Write QC
        write(qc, paste0(name, '.qc.txt'))
        
        # Write gene level // use hisensitivity run
        gene_level = gene_level_changes(hisens_output, args$genome) %>% 
            add_column(sample = sample_id, .before = 1)
        write(gene_level, paste0(name, '.gene_level.txt'))
        
        # Write arm level // use purity run
        arm_level = arm_level_changes(purity_output$segs, purity_output$ploidy, args$genome) %>% 
            pluck('full_output') %>% 
            add_column(sample = sample_id, .before = 1)
        write(arm_level, paste0(name, '.arm_level.txt'))
    }
    
    run_details = print_run_details(outfile = ifelse(args$legacy_output, '/dev/null', paste0(name, '.txt')),
                                    run_type = c('purity', 'hisens'),
                                    cval = c(args$purity_cval, args$cval),
                                    min_nhet = c(args$purity_min_nhet, args$min_nhet),
                                    purity = c(purity_output$purity, hisens_output$purity),
                                    ploidy = c(purity_output$ploidy, hisens_output$ploidy),
                                    dipLogR = c(purity_output$dipLogR, hisens_output$dipLogR),
                                    flags = unlist(map(list(purity_output$flags, hisens_output$flags), 
                                                       function(x) paste0(x, collapse = '; '))),
                                    metadata)
    
    if (args$legacy_output) {
        create_legacy_output(hisens_output, directory, sample_id, args$counts_file, 'hisens', run_details)
        create_legacy_output(purity_output, directory, sample_id, args$counts_file, 'purity', run_details)
    } else {
        # Write RDS
        saveRDS(purity_output, paste0(name, '_purity.rds'))
        saveRDS(hisens_output, paste0(name, '_hisens.rds'))
    }
    
} else {
    name = paste0(directory, '/', sample_id)

    output = facets_iteration(name_prefix = name,
                              dipLogR = args$dipLogR,
                              cval = args$cval,
                              ndepth = args$normal_depth,
                              snp_nbhd = args$snp_window_size,
                              min_nhet = args$min_nhet,
                              genome = args$genome,
                              seed = args$seed,
                              facets_lib_path = args$facets_lib_path)
    
    metadata = NULL
    if (args$everything) {
        metadata = c(
            arm_level_changes(output$segs, output$ploidy, args$genome),
            calculate_lst(output$segs, output$ploidy, args$genome),
            calculate_ntai(output$segs, output$ploidy, args$genome),
            calculate_hrdloh(output$segs, output$ploidy),
            calculate_loh(output$segs, output$snps, args$genome)
        )
        
        # Write QC
        qc = check_fit(output, genome = args$genome)
        qc = c(sample = sample_id, cval = args$cval, qc)
        write(qc, paste0(name, '.qc.txt'))
        
        # Write gene level
        gene_level = gene_level_changes(output, args$genome) %>% 
            add_column(sample = sample_id, .before = 1)
        write(gene_level, paste0(name, '.gene_level.txt'))
        
        # Write arm level
        arm_level = add_column(metadata$full_output, sample = sample_id, .before = 1)
        write(arm_level, paste0(name, '.arm_level.txt'))
    }
    
    # Write run details/metadata
    run_details =
        print_run_details(outfile = ifelse(args$legacy_output, '/dev/null', paste0(name, '.txt')),
                          run_type = '',
                          cval = args$cval,
                          min_nhet = args$min_nhet,
                          purity = output$purity,
                          ploidy = output$ploidy,
                          dipLogR = output$ploidy,
                          flags = paste0(output$flags, collapse = '; '),
                          metadata)
    
    # Write RDS
    if (args$legacy_output) {
        create_legacy_output(output, directory, sample_id, args$counts_file, '', run_details)
    } else {
        saveRDS(output, paste0(directory, '/', sample_id, '.rds'))
    }
}
