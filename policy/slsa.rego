package fts_quadlet.slsa

import rego.v1

deny contains msg if {
    input.event_name == "release"
    not input.slsa_provenance_attached
    msg := "SLSA: release must have provenance attached before upload"
}

deny contains msg if {
    input.slsa_verifier_exit_code != 0
    msg := sprintf("SLSA: slsa-verifier failed with exit code %d",
                   [input.slsa_verifier_exit_code])
}
