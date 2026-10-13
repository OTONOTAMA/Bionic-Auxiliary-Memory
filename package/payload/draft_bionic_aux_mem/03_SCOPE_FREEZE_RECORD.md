<META>
BUNDLE_CLASS=DOMAIN_BUNDLE
SPECIFICATION_CLASS=SCOPE_FREEZE_RECORD
CANONICAL_LANGUAGE=ENGLISH_STRUCTURED_WITH_JAPANESE_SECTIONS
STATUS=DISTRIBUTION_FREEZE_PASS
DATE=2026-10-12
DOCUMENT_ROLE=DISTRIBUTION_VARIANT
SOURCE_FREEZE_DATE=2026-10-06
SOURCE_FREEZE_RESULT=PASS (scope freeze in the source environment)
IMPLEMENTATION_AUTHORIZATION=NOT_GRANTED
NEXT_GATE=DISTRIBUTION_TARGET_INSTALLATION (bamp1.ps1 procedure; separate user approval)
</META>

<PHASE_GATE>
PHASE=SCOPE_FREEZE_RECORD
IMPLEMENTATION=PROHIBITED
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
</AUTHORITY>

## 1. Purpose of this record

This record is the scope freeze record for the distribution variant. It freezes the three
distribution documents REQ / 01 / 02 by (source original hash, distribution hash) pairs.
The source original is the frozen scope freeze record of the source environment
(2026-10-06, PASS); its source hashes are carried over unchanged. The distribution hashes
were the measured values of the distributed documents at assembly time (2026-10-12).
v3 amendment (2026-10-13): distribution hashes re-measured after the Part I English
translation of REQ and the two-part rename of the human-guidance document
(02_HUMAN_GUIDANCE.md); source hashes unchanged. Absolute paths of the source
environment are omitted from the distribution.

## 2. Core scope

The distribution scope follows the DISTRIBUTION SCOPE ADDENDUM (appended to each distributed
document): Core only (retain / fast recall / lifecycle / status / validate / write and
integrity mechanism + tool-side FilterDeepOut machine mode). The deep recall execution path,
L0-L3-dependent live behavior, and real-compaction cases are out of scope.

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
