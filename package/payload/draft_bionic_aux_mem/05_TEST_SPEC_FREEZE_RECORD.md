<META>
BUNDLE_CLASS=DOMAIN_BUNDLE
SPECIFICATION_CLASS=TEST_SPEC_FREEZE_RECORD
CANONICAL_LANGUAGE=ENGLISH_STRUCTURED_WITH_JAPANESE_SECTIONS
STATUS=DISTRIBUTION_FREEZE_PASS
DATE=2026-10-12
DOCUMENT_ROLE=DISTRIBUTION_VARIANT
SOURCE_FREEZE_DATE=2026-10-07
SOURCE_FREEZE_RESULT=PASS (test-specification freeze in the source environment)
IMPLEMENTATION_AUTHORIZATION=NOT_GRANTED
NEXT_GATE=DISTRIBUTION_TARGET_INSTALLATION (bamp1.ps1 procedure; separate user approval)
</META>

<PHASE_GATE>
PHASE=TEST_SPEC_FREEZE_RECORD
IMPLEMENTATION=PROHIBITED
TEST_EXECUTION=PROHIBITED
PRODUCTION_CHANGE=PROHIBITED
</PHASE_GATE>

<AUTHORITY>
REQUIREMENTS_AUTHORITY=[
"BIONIC_AUXILIARY_MEMORY_REQUIREMENTS_v0.3.md (document name only; absolute path omitted from distribution)"
"SOURCE_SHA256=5E355136C62E9728B39C1AF19A2D65A569916604DE55F09090A3203CC203CC2A"
"DISTRIBUTION_SHA256=FEAE3670A6437D68D0E324AEBC4D0705677AE9C6684E4F484A192092C5AF547B"
]
FROZEN_SPECIFICATION=[
"01_CANONICAL_NORMATIVE_SPECIFICATION.md (document name only; absolute path omitted from distribution)"
"SOURCE_SHA256=E8EA13E9743747205421548ECB385CF8E92026A07B30025376CBBAD723DB9A11"
"DISTRIBUTION_SHA256=65ACEF51E47649F59E072E72CEFA7FCEE0FAEC5D625379761D3DE1EE78F6F62A"
]
FROZEN_HUMAN_GUIDANCE=[
"02_JA_HUMAN_GUIDANCE.md (frozen source document name only; absolute path omitted from distribution)"
"SOURCE_SHA256=9020A6F5858D7773286983A7B4EAEB1453C8C34DD4CD7AD7836F9B7FFDBE138C"
"DISTRIBUTION_FILE=02_HUMAN_GUIDANCE.md (v3 2026-10-13: renamed, two-part EN/JA; v3.1/v3.2: PART II carries documented adaptations, see 02 provenance header)"
"DISTRIBUTION_SHA256=E31336E62B8CF69E0C6D34E0BE95D395760B96A14B89FB2339FF54521FF6632E"
]
SCOPE_FREEZE_RECORD=[
"03_SCOPE_FREEZE_RECORD.md (document name only; absolute path omitted from distribution)"
"SOURCE_SHA256=BCFFCB780B203C1F58806EF7214C08A8054B418F817DAEE85F010D4D870C30DF"
"DISTRIBUTION_SHA256=CA0209775961F60A404BF63C7F569F17B4E0B517FF3D8213A30059A156A9EB04"
]
TEST_SPECIFICATION=[
"04_TEST_FIRST_SPECIFICATION.md (document name only; absolute path omitted from distribution)"
"SOURCE_SHA256=92095A477C2D5205C32856F3DFD6870EEF61C04F2747752C4200489AEE89D163"
"DISTRIBUTION_SHA256=67E0AF016D6FC8E3255C3EB61CC3FAB2A4D8E1892BCD5B846C0AE3EFD280B57D"
]
</AUTHORITY>

## 1. Purpose of this record

This record is the test-specification freeze record for the distribution variant. It freezes
the five distribution documents REQ / 01..04 by (source original hash, distribution hash)
pairs. The source original is the frozen test-specification freeze record of the source
environment (2026-10-07, PASS); its source hashes are carried over unchanged. The
distribution hashes were the measured values of the distributed documents at assembly
time (2026-10-12). v3 amendment (2026-10-13): distribution hashes re-measured after
the Part I English translation of REQ, the two-part rename of the human-guidance
document (02_HUMAN_GUIDANCE.md), and the consequent re-measurement of 03 itself;
source hashes unchanged. Absolute paths of the source environment are omitted from
the distribution.

## 2. Test handling

The machine 95-case selftest suite (runner) is the execution target of this distribution.
The 24 LIVE_BEHAVIORAL cases are the source environment acceptance suite; in the distribution
target only the PROCEDURE.md minimal live check (fresh-chat probe) is executed. offload /
L0-L3 / real-compaction dependent IDs are recorded NOT_RUN in the distribution target.

## 3. Authorization

This record grants no implementation authorization (IMPLEMENTATION_AUTHORIZATION=NOT_GRANTED).
Installation on a distribution target environment is executed via the bamp1.ps1 procedure and
requires the user's own approval.


---

## DISTRIBUTION SCOPE ADDENDUM (2026-10-12)

This section is a distribution addendum of the portable Core package (bamp1-portable, 2026-10-12).
It does not change the frozen body above. It defines the distribution scope.

1. Core scope: retain / fast recall / lifecycle (supersede / forget / restore) / status / validate /
   write and integrity mechanism. In addition, the tool-side FilterDeepOut mode (pure file filter,
   no offload needed, machine-tested; runner Group F = AM-T-018.a-i) is included in this distribution.
2. Out of scope: the deep recall execution path (01 D7 api-context-offload mechanism, strong-model
   candidate generation) / live behavior depending on the source environment L0-L3 discipline /
   real-compaction-dependent cases.
3. Relation to the original specification: 01 D7/D8 clauses 4/9 and REQ AM-F-015..017 / AM-I-014 /
   AM-C-005 / AM-T-018..019 (live) are kept verbatim (frozen) in the body but are NOT provided in this
   distribution. Deep recall is conditioned on the capability being verified available (REQ AM-F-015);
   in the distribution target it is not provided = report as unavailable (BLOCKED) on explicit request
   (no fabrication, no substitute).
4. Requirement/test handling in this distribution: machine 95 cases (runner, incl. FilterDeepOut group)
   = execution target (distribution selftest). The 24 LIVE_BEHAVIORAL cases of 04 are the source
   environment acceptance suite; in the distribution target only the PROCEDURE.md minimal live check
   (fresh-chat probe) is executed. offload-dependent (018/019), L0-L3-dependent and real-compaction
   dependent IDs are recorded NOT_RUN in the distribution target.
5. This addendum is identical across all distributed documents (REQ / 01..05).
