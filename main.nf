#!/usr/bin/env nextflow
/*
========================================================================================
                         nf-core/bamtofastq
========================================================================================
 nf-core/bamtofastq Analysis Pipeline.
 #### Homepage / Documentation
 https://github.com/nf-core/bamtofastq
----------------------------------------------------------------------------------------
*/

def helpMessage() {
    // TODO nf-core: Add to this help message with new command line parameters
    log.info nfcoreHeader()
    log.info"""

    Usage:

    The typical command for running the pipeline is as follows:

    nextflow run nf-core/bamtofastq --reads '*_R{1,2}.fastq.gz' -profile docker

    Mandatory arguments:
      --bam                       Path to input data (must be surrounded with quotes)
      -profile                      Configuration profile to use. Can use multiple (comma separated)
                                    Available: conda, docker, singularity, awsbatch, test and more.

    Other options:
      --outdir                      The output directory where the results will be saved
      --email                       Set this parameter to your e-mail address to get a summary e-mail with details of the run sent to you when the workflow exits
      --email_on_fail               Same as --email, except only send mail if the workflow is not successful
      --maxMultiqcEmailFileSize     Theshold size for MultiQC report to be attached in notification email. If file generated by pipeline exceeds the threshold, it will not be attached (Default: 25MB)
      -name                         Name for the pipeline run. If not specified, Nextflow will automatically generate a random mnemonic.

    AWSBatch options:
      --awsqueue                    The AWSBatch JobQueue that needs to be set when running on AWSBatch
      --awsregion                   The AWS Region for your AWS Batch job to run on
    """.stripIndent()
}

// Show help message
if (params.help) {
    helpMessage()
    exit 0
}

/*
 * SET UP CONFIGURATION VARIABLES
 */

// TODO nf-core: Add any reference files that are needed
// Configurable reference genomes

// Has the run name been specified by the user?
//  this has the bonus effect of catching both -name and --name
custom_runName = params.name
if (!(workflow.runName ==~ /[a-z]+_[a-z]+/)) {
  custom_runName = workflow.runName
}

if ( workflow.profile == 'awsbatch') {
  // AWSBatch sanity checking
  if (!params.awsqueue || !params.awsregion) exit 1, "Specify correct --awsqueue and --awsregion parameters on AWSBatch!"
  // Check outdir paths to be S3 buckets if running on AWSBatch
  // related: https://github.com/nextflow-io/nextflow/issues/813
  if (!params.outdir.startsWith('s3:')) exit 1, "Outdir not on S3 - specify S3 Bucket to run on AWSBatch!"
  // Prevent trace files to be stored on S3 since S3 does not support rolling files.
  if (workflow.tracedir.startsWith('s3:')) exit 1, "Specify a local tracedir or run without trace! S3 cannot be used for tracefiles."
}

// Stage config files
ch_multiqc_config = file(params.multiqc_config, checkIfExists: true)
ch_output_docs = file("$baseDir/docs/output.md", checkIfExists: true)

/*
 * Create a channel for input bam files
 */

if(params.bam) { //Checks whether bam file(s) was specified
    Channel
        .fromPath(params.bam, checkIfExists: true) //checks whether the specified file exists, somehow i don't get a local error message, but in all other pipelines on the cluser it seems to work. TODO, what if only one file is faulty? this seems to cause the pipeline to fail completely 
        .map { file -> tuple(file.name.replaceAll(".bam",''), file) } // map bam file name w/o bam to file 
        .set { bam_files_check } //else send to first process
        
} else{
     exit 1, "Parameter 'params.bam' was not specified!\n"
}


// Header log info
log.info nfcoreHeader()
def summary = [:]
if (workflow.revision) summary['Pipeline Release'] = workflow.revision
summary['Run Name']         = custom_runName ?: workflow.runName
// TODO nf-core: Report custom parameters here
summary['Bam']            = params.bam
summary['Max Resources']    = "$params.max_memory memory, $params.max_cpus cpus, $params.max_time time per job"
if (workflow.containerEngine) summary['Container'] = "$workflow.containerEngine - $workflow.container"
summary['Output dir']       = params.outdir
summary['Launch dir']       = workflow.launchDir
summary['Working dir']      = workflow.workDir
summary['Script dir']       = workflow.projectDir
summary['User']             = workflow.userName
if (workflow.profile == 'awsbatch') {
  summary['AWS Region']     = params.awsregion
  summary['AWS Queue']      = params.awsqueue
}
summary['Config Profile'] = workflow.profile
if (params.config_profile_description) summary['Config Description'] = params.config_profile_description
if (params.config_profile_contact)     summary['Config Contact']     = params.config_profile_contact
if (params.config_profile_url)         summary['Config URL']         = params.config_profile_url
if (params.email || params.email_on_fail) {
  summary['E-mail Address']    = params.email
  summary['E-mail on failure'] = params.email_on_fail
  summary['MultiQC maxsize']   = params.maxMultiqcEmailFileSize
}
log.info summary.collect { k,v -> "${k.padRight(18)}: $v" }.join("\n")
log.info "-\033[2m--------------------------------------------------\033[0m-"

// Check the hostnames against configured profiles
checkHostname()

def create_workflow_summary(summary) {
    def yaml_file = workDir.resolve('workflow_summary_mqc.yaml')
    yaml_file.text  = """
    id: 'nf-core-bamtofastq-summary'
    description: " - this information is collected when the pipeline is started."
    section_name: 'nf-core/bamtofastq Workflow Summary'
    section_href: 'https://github.com/nf-core/bamtofastq'
    plot_type: 'html'
    data: |
        <dl class=\"dl-horizontal\">
${summary.collect { k,v -> "            <dt>$k</dt><dd><samp>${v ?: '<span style=\"color:#999999;\">N/A</a>'}</samp></dd>" }.join("\n")}
        </dl>
    """.stripIndent()

   return yaml_file
}

/*
 * Parse software version numbers
 */
process get_software_versions {
    publishDir "${params.outdir}/pipeline_info", mode: 'copy',
        saveAs: { filename ->
            if (filename.indexOf(".csv") > 0) filename
            else null
        }

    output:
    file 'software_versions_mqc.yaml' into software_versions_yaml
    file "software_versions.csv"
    file "*.txt"

    script:
    // TODO nf-core: Get all tools to print their version number here
    """
    echo $workflow.manifest.version > v_pipeline.txt
    echo $workflow.nextflow.version > v_nextflow.txt
    multiqc --version > v_multiqc.txt
    samtools --version > v_samtools.txt
    echo \$(pigz --version 2>&1) > v_pigz.txt
    scrape_software_versions.py &> software_versions_mqc.yaml
    """
}

/*
 * STEP 1: Check for paired-end or single-end bam
 */
process checkIfPairedEnd{
  tag "$name"
  publishDir "${params.outdir}/checkPairedEnd", pattern: '*.txt', mode: 'copy'

  input:
  set val(name), file(bam) from bam_files_check

  output:
  set val(name), file(bam), file('*paired.txt') optional true into bam_files_paired_map_map,      
                                                                   bam_files_paired_unmap_unmap, bam_files_paired_unmap_map, bam_files_paired_map_unmap
  set val(name), file(bam), file('*single.txt') optional true into bam_file_single_end //aka is not paired end
  file "*.{flagstat,idxstats,stats}" into ch_bam_flagstat_mqc
  file "*.{zip,html}" into ch_fastqc_reports_mqc_bam

  script:
  """
  # Take samtools header + the first 1000 reads (to safe time, otherwise also all can be used) and check whether for 
  # all, the flag for paired-end is set. Compare: https://www.biostars.org/p/178730/ . 
  # TODO:  Store results in var instead of file:  feature will be available in v20.01.0 https://github.com/nextflow-io/nextflow/issues/69

  if [ \$({ samtools view -H $bam ; samtools view $bam | head -n1000; } | samtools view -c -f 1  | awk '{print \$1/1000}') = "1" ]; then 
    echo 1 > ${name}.paired.txt
  else
    echo 0 > ${name}.single.txt
  fi

  samtools flagstat $bam > ${bam}.flagstat
  samtools idxstats $bam > ${bam}.idxstats
  samtools stats $bam > ${bam}.stats
  fastqc -q -t $task.cpus $bam
  """

}

/*
 * Step 2a: Handle paired-end bams
 */
process pairedEndMapMap{
  tag "$name"

  input:
  set val(name), file(bam), file(txt) from bam_files_paired_map_map

  output:
  set val(name), file( '*.map_map.bam') into map_map_bam 

  when:
  txt.exists()

  script:
  """
  samtools view -u -f1 -F12 $bam -@ ${task.cpus} > ${name}.map_map.bam
  """
}

process pairedEndUnmapUnmap{
  tag "$name"

  input:
  set val(name), file(bam), file(txt) from bam_files_paired_unmap_unmap

  output:
  set val(name), file('*.unmap_unmap.bam') into unmap_unmap_bam 

  when:
  txt.exists()

  script:
  """
  samtools view -u -f12 -F256 $bam -@ ${task.cpus} > ${name}.unmap_unmap.bam
  """
}

process pairedEndUnmapMap{
  tag "$name"

  input:
  set val(name), file(bam), file(txt) from bam_files_paired_unmap_map

  output:
  set val(name), file( '*.unmap_map.bam') into unmap_map_bam 

  when:
  txt.exists()

  script:
  """
  samtools view -u -f4 -F264 $bam -@ ${task.cpus} > ${name}.unmap_map.bam
  """
}

process pairedEndMapUnmap{
  tag "$name"

  input:
  set val(name), file(bam), file(txt) from bam_files_paired_map_unmap

  output:
  set val(name), file( '*.map_unmap.bam') into map_unmap_bam 

  when:
  txt.exists()

  script:
  """
  samtools view -u -f8 -F260 $bam  -@ ${task.cpus} > ${name}.map_unmap.bam
  """
}

unmap_unmap_bam.join(map_unmap_bam, remainder: true)
               .join(unmap_map_bam, remainder: true)
               .set{ all_unmapped_bam }

process mergeUnmapped{
  tag "$name"

  input:
  set val(name), file(unmap_unmap), file (map_unmap),  file(unmap_map) from all_unmapped_bam

  output:
  set val(name), file('*.merged_unmapped.bam') into merged_unmapped 

  script:
  """
  samtools merge -u ${name}.merged_unmapped.bam $unmap_unmap $map_unmap $unmap_map  -@ ${task.cpus}
  """
}

process sortMapped{
  label 'process_medium'
  tag "$name"

  input:
  set val(name), file(all_map_bam) from map_map_bam

  output:
  set val(name), file('*.sort') into sort_mapped

  script:
  """
  samtools collate $all_map_bam -o ${name}_mapped.sort -@ $task.cpu
  """
}

process sortUnmapped{
  label 'process_medium'
  tag "$name"
 
  input:
  set val(name), file(all_unmapped) from merged_unmapped

  output:
  set val(name), file('*.sort') into sort_unmapped

  script:
  """
  samtools collate $all_unmapped -o ${name}_unmapped.sort -@ $task.cpu
  """
}

process extractMappedReads{
  label 'process_medium'
  tag "$name"

  input:
  set val(name), file(sort) from sort_mapped

  output:
  set val(name), file('*mapped.fq') into reads_mapped
  //file ('*singletons.fq') //This should always be empty, as only mapped_mapped are extracted

  script:
  """
  # bamToFastq -i $sort -fq ${name}_R1_mapped.fq -fq2 ${name}_R2_mapped.fq
  # TODO: Is this really correct. The samtools instructions are very weird
  samtools fastq $sort -1 ${name}_R1_mapped.fq -2 ${name}_R2_mapped.fq -s ${name}_mapped_singletons.fq -N -@ $task.cpu
  """
}

process extractUnmappedReads{
  label 'process_medium'
  tag "$name"

  input:
  set val(name), file(sort) from sort_unmapped

  output:
  set val(name), file('*unmapped.fq') into reads_unmapped
  //file ('*singletons.fq') // There may be something in here, if for some reason out of a sequencer there was a singleton present. Other than that each read should have a pair as reads are from (unm_unm, m_unm, unm_m). Actually the singletons file should also be empty as only pairs are extracted as well. 

  script:
  """
  # bamToFastq -i $sort -fq ${name}_R1_unmapped.fq -fq2 ${name}_R2_unmapped.fq
  # Multithreading only work for compression, since we can't compress here, can prob delete this or double check whether samtools or bedtools is faster
  # TODO: Is this really correct. The samtools instructions are very weird
  samtools fastq $sort -1 ${name}_R1_unmapped.fq -2 ${name}_R2_unmapped.fq -s ${name}_unmapped_singletons.fq -N -@ $task.cpu
  """
}

reads_mapped.join(reads_unmapped, remainder: true)
            .map{
              row -> tuple(row[0], row[1][0], row[1][1], row[2][0], row[2][1])
            }
            .set{ all_fastq }


process joinMappedAndUnmappedFastq{
  tag "$name"
  publishDir "${params.outdir}/reads", mode: 'copy', enabled: !params.gz

  input:
  set val(name), file(mapped_fq1), file(mapped_fq2), file(unmapped_fq1), file(unmapped_fq2) from all_fastq.filter{ it.size()>0 }

  output:
  set file('*1.fq'), file('*2.fq') into read_files
  file "*.{zip,html}" into ch_fastqc_reports_mqc

  script:
  """
  cat $mapped_fq1 $unmapped_fq1 > ${name}.1.fq
  cat $mapped_fq2 $unmapped_fq2 > ${name}.2.fq

  fastqc -q -t $task.cpus ${name}.1.fq
  fastqc -q -t $task.cpus ${name}.2.fq 
  """
}

process compressFiles{
  tag "$read1"
  label 'process_long'
  publishDir "${params.outdir}/reads", mode: 'copy'

  input:
  set file(read1), file(read2) from read_files

  output:
  file('*.gz') into fastq_gz

  when:
  params.gz

  script:
  """
  pigz -f -p ${task.cpus} -k $read1 $read2
  """
}

//TODO: Make sure only uniqely mapped reads are used!!!!! Maybe samtools is taking care of this after all????+


/*
 * STEP 2b: Handle single-end bams 
 */
process singleEndSort{
    tag "$name"

    input:
    set val(name), file(bam), file(txt) from bam_file_single_end
    
    output:
    set val(name), file ('*.sort') into sort_single_end

    when:
    txt.exists()

    script:
    """
    samtools collate $bam -o ${name}.sort -@ ${task.cpus}
    """
 } 

process singleEndExtract{
    tag "$name"
    publishDir "${params.outdir}/reads", mode: 'copy'

    input:
    set val(name), file(sort) from sort_single_end
    
    output:
    file ('*.singleton.fq*')
    file "*.{zip,html}" into ch_se_fastqc_reports_mqc
    
    script:
    if(params.gz){
      """
      samtools fastq $sort -0 ${name}.singleton.fq.gz  -@ ${task.cpus}
      fastqc -q -t $task.cpus ${name}.singleton.fq.gz
      """
    }else{
      """
      # TODO: Is this really correct. The samtools instructions are very weird
      # TODO: set params.gz condition, maybe test this next step also with all possible output files  
      samtools fastq $sort -0 ${name}.singleton.fq  -@ ${task.cpus}

      fastqc -q -t $task.cpus ${name}.singleton.fq
      """
    }
 } 

/*
 * STEP 3 - Output Description HTML
 */
process output_documentation {
    publishDir "${params.outdir}/pipeline_info", mode: 'copy'

    input:
    file output_docs from ch_output_docs

    output:
    file "results_description.html"

    script:
    """
    markdown_to_html.r $output_docs results_description.html
    """
}

/*
 * STEP 4 - MultiQC
 */
process multiqc {
    publishDir "${params.outdir}/MultiQC", mode: 'copy'

    input:
    file multiqc_config from ch_multiqc_config
    // TODO nf-core: Add in log files from your new processes for MultiQC to find!
    file fastqc from ch_se_fastqc_reports_mqc.collect().ifEmpty([])
    file fastqc1 from ch_fastqc_reports_mqc.collect().ifEmpty([])
    file fastqc2 from ch_fastqc_reports_mqc_bam.collect().ifEmpty([])

    file ('software_versions/*') from software_versions_yaml.collect()
    file workflow_summary from create_workflow_summary(summary)
    file samstats from ch_bam_flagstat_mqc.collect()

    output:
    file "*multiqc_report.html" into ch_multiqc_report
    file "*_data"
    file "multiqc_plots"

    script:
    rtitle = custom_runName ? "--title \"$custom_runName\"" : ''
    rfilename = custom_runName ? "--filename " + custom_runName.replaceAll('\\W','_').replaceAll('_+','_') + "_multiqc_report" : ''
    """
    multiqc . -f $rtitle $rfilename --config $multiqc_config  \\
      -m samtools -m fastqc
    """
}

/*
 * Completion e-mail notification
 */
workflow.onComplete {

    // Set up the e-mail variables
    def subject = "[nf-core/bamtofastq] Successful: $workflow.runName"
    if (!workflow.success) {
      subject = "[nf-core/bamtofastq] FAILED: $workflow.runName"
    }
    def email_fields = [:]
    email_fields['version'] = workflow.manifest.version
    email_fields['runName'] = custom_runName ?: workflow.runName
    email_fields['success'] = workflow.success
    email_fields['dateComplete'] = workflow.complete
    email_fields['duration'] = workflow.duration
    email_fields['exitStatus'] = workflow.exitStatus
    email_fields['errorMessage'] = (workflow.errorMessage ?: 'None')
    email_fields['errorReport'] = (workflow.errorReport ?: 'None')
    email_fields['commandLine'] = workflow.commandLine
    email_fields['projectDir'] = workflow.projectDir
    email_fields['summary'] = summary
    email_fields['summary']['Date Started'] = workflow.start
    email_fields['summary']['Date Completed'] = workflow.complete
    email_fields['summary']['Pipeline script file path'] = workflow.scriptFile
    email_fields['summary']['Pipeline script hash ID'] = workflow.scriptId
    if (workflow.repository) email_fields['summary']['Pipeline repository Git URL'] = workflow.repository
    if (workflow.commitId) email_fields['summary']['Pipeline repository Git Commit'] = workflow.commitId
    if (workflow.revision) email_fields['summary']['Pipeline Git branch/tag'] = workflow.revision
    if (workflow.container) email_fields['summary']['Docker image'] = workflow.container
    email_fields['summary']['Nextflow Version'] = workflow.nextflow.version
    email_fields['summary']['Nextflow Build'] = workflow.nextflow.build
    email_fields['summary']['Nextflow Compile Timestamp'] = workflow.nextflow.timestamp

    // TODO nf-core: If not using MultiQC, strip out this code (including params.maxMultiqcEmailFileSize)
    // On success try attach the multiqc report
    def mqc_report = null
    try {
        if (workflow.success) {
            mqc_report = multiqc_report.getVal()
            if (mqc_report.getClass() == ArrayList) {
                log.warn "[nf-core/bamtofastq] Found multiple reports from process 'multiqc', will use only one"
                mqc_report = mqc_report[0]
            }
        }
    } catch (all) {
        log.warn "[nf-core/bamtofastq] Could not attach MultiQC report to summary email"
    }

    // Check if we are only sending emails on failure
    email_address = params.email
    if (!params.email && params.email_on_fail && !workflow.success) {
        email_address = params.email_on_fail
    }

    // Render the TXT template
    def engine = new groovy.text.GStringTemplateEngine()
    def tf = new File("$baseDir/assets/email_template.txt")
    def txt_template = engine.createTemplate(tf).make(email_fields)
    def email_txt = txt_template.toString()

    // Render the HTML template
    def hf = new File("$baseDir/assets/email_template.html")
    def html_template = engine.createTemplate(hf).make(email_fields)
    def email_html = html_template.toString()

    // Render the sendmail template
    def smail_fields = [ email: email_address, subject: subject, email_txt: email_txt, email_html: email_html, baseDir: "$baseDir", mqcFile: mqc_report, mqcMaxSize: params.maxMultiqcEmailFileSize.toBytes() ]
    def sf = new File("$baseDir/assets/sendmail_template.txt")
    def sendmail_template = engine.createTemplate(sf).make(smail_fields)
    def sendmail_html = sendmail_template.toString()

    // Send the HTML e-mail
    if (email_address) {
        try {
          if ( params.plaintext_email ){ throw GroovyException('Send plaintext e-mail, not HTML') }
          // Try to send HTML e-mail using sendmail
          [ 'sendmail', '-t' ].execute() << sendmail_html
          log.info "[nf-core/bamtofastq] Sent summary e-mail to $email_address (sendmail)"
        } catch (all) {
          // Catch failures and try with plaintext
          [ 'mail', '-s', subject, email_address ].execute() << email_txt
          log.info "[nf-core/bamtofastq] Sent summary e-mail to $email_address (mail)"
        }
    }

    // Write summary e-mail HTML to a file
    def output_d = new File( "${params.outdir}/pipeline_info/" )
    if (!output_d.exists()) {
      output_d.mkdirs()
    }
    def output_hf = new File( output_d, "pipeline_report.html" )
    output_hf.withWriter { w -> w << email_html }
    def output_tf = new File( output_d, "pipeline_report.txt" )
    output_tf.withWriter { w -> w << email_txt }

    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_red = params.monochrome_logs ? '' : "\033[0;31m";

    if (workflow.stats.ignoredCount > 0 && workflow.success) {
      log.info "${c_purple}Warning, pipeline completed, but with errored process(es) ${c_reset}"
      log.info "${c_red}Number of ignored errored process(es) : ${workflow.stats.ignoredCount} ${c_reset}"
      log.info "${c_green}Number of successfully ran process(es) : ${workflow.stats.succeedCount} ${c_reset}"
    }

    if (workflow.success) {
        log.info "${c_purple}[nf-core/bamtofastq]${c_green} Pipeline completed successfully${c_reset}"
    } else {
        checkHostname()
        log.info "${c_purple}[nf-core/bamtofastq]${c_red} Pipeline completed with errors${c_reset}"
    }

}


def nfcoreHeader(){
    // Log colors ANSI codes
    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_dim = params.monochrome_logs ? '' : "\033[2m";
    c_black = params.monochrome_logs ? '' : "\033[0;30m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_yellow = params.monochrome_logs ? '' : "\033[0;33m";
    c_blue = params.monochrome_logs ? '' : "\033[0;34m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_cyan = params.monochrome_logs ? '' : "\033[0;36m";
    c_white = params.monochrome_logs ? '' : "\033[0;37m";

    return """    -${c_dim}--------------------------------------------------${c_reset}-
                                            ${c_green},--.${c_black}/${c_green},-.${c_reset}
    ${c_blue}        ___     __   __   __   ___     ${c_green}/,-._.--~\'${c_reset}
    ${c_blue}  |\\ | |__  __ /  ` /  \\ |__) |__         ${c_yellow}}  {${c_reset}
    ${c_blue}  | \\| |       \\__, \\__/ |  \\ |___     ${c_green}\\`-._,-`-,${c_reset}
                                            ${c_green}`._,._,\'${c_reset}
    ${c_purple}  nf-core/bamtofastq v${workflow.manifest.version}${c_reset}
    -${c_dim}--------------------------------------------------${c_reset}-
    """.stripIndent()
}

def checkHostname(){
    def c_reset = params.monochrome_logs ? '' : "\033[0m"
    def c_white = params.monochrome_logs ? '' : "\033[0;37m"
    def c_red = params.monochrome_logs ? '' : "\033[1;91m"
    def c_yellow_bold = params.monochrome_logs ? '' : "\033[1;93m"
    if (params.hostnames) {
        def hostname = "hostname".execute().text.trim()
        params.hostnames.each { prof, hnames ->
            hnames.each { hname ->
                if (hostname.contains(hname) && !workflow.profile.contains(prof)) {
                    log.error "====================================================\n" +
                            "  ${c_red}WARNING!${c_reset} You are running with `-profile $workflow.profile`\n" +
                            "  but your machine hostname is ${c_white}'$hostname'${c_reset}\n" +
                            "  ${c_yellow_bold}It's highly recommended that you use `-profile $prof${c_reset}`\n" +
                            "============================================================"
                }
            }
        }
    }
}
