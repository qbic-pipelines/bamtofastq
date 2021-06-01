# nf-core/bamtofastq: Changelog

## v1.1.1 - Katherine Johnson faster

- [#31](https://github.com/qbic-pipelines/bamtofastq/pull/31) Add option `--samtools_collate_fast` and improve speed of cat.
- [#32](https://github.com/qbic-pipelines/bamtofastq/pull/32) Added `--samtools_collate_fast` to sortExtractMapped and changed cat command to append.
- [#33](https://github.com/qbic-pipelines/bamtofastq/pull/33) Added flag `--reads_in_memory` to specify how many reads shall be stored in memory.
- [#34](https://github.com/qbic-pipelines/bamtofastq/pull/34) Added new flags to summary and enabled fast compression mode by default.

## v1.1.0 -  Katherine Johnson

- [#21](https://github.com/qbic-pipelines/bamtofastq/21) Allows bam indices as additional input files
- [#23](https://github.com/qbic-pipelines/bamtofastq/23) Fix documentation: `--bam` is `--input` now
- [#23](https://github.com/qbic-pipelines/bamtofastq/23) Make stats computation optional with parameter `--no_stats`. Use at own risk.
- [#26](https://github.com/qbic-pipelines/bamtofastq/26) `BAM` index is now also used for processes dealing with separating reads based on the mapping status of both mates

## v1.0.0 - Ada Lovelace

Initial release of qbic-pipelines/bamtofastq, created with the [nf-core](http://nf-co.re/) template.
