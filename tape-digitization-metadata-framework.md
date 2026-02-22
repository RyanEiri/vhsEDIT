# Metadata Collection Framework for Tape Digitization

## Overview
Metadata collection points for personal tape digitization workflow using bellboy and post-processing pipeline.

## Pre-Capture Metadata
*Collected before bellboy starts*

- **Tape identification/label** - Physical label or identifier on the tape
- **Format details** - Specific format (VHS, Hi8, MiniDV, etc.)
- **Source information** - Whose tape, provenance
- **Approximate date** - Recording date if known or estimated
- **Condition notes** - Any visible damage, mold, or deterioration observed

## During Capture Metadata
*Provided by bellboy and capture process*

- **Capture timestamp** - Actual date/time of digitization
- **Duration** - Length of captured content
- **Technical specifications**
  - Resolution
  - Codec
  - Bitrate
- **Error flags** - Any dropout or error indicators during capture

## Post-Processing Metadata
*Generated after capture completion*

- **File hashes** - For fixity checking (SHA-256 recommended for OAIS compliance)
- **Derivative formats** - List of any transcoded or normalized versions created
- **Processing pipeline details**
  - Pipeline version
  - Parameters used
  - Processing date/time

## Implementation Notes

### OAIS Alignment
Structure metadata as JSON sidecar files that travel with each capture, creating a basic AIP (Archival Information Package) structure suitable for personal collections.

### Storage Format
Recommend JSON sidecar files (one per tape capture) for:
- Easy machine readability
- Future migration flexibility
- Integration with static site/Lunr search systems

### Workflow Integration
Metadata collection points align with existing pipeline stages:
1. Pre-capture: Manual entry or prompted collection
2. During capture: Automatic extraction from bellboy
3. Post-processing: Automatic generation during pipeline completion
