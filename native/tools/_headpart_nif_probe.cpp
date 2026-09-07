#include "bsa/bsa_archive.h"
#include "nif/nif_loader.h"
#include <cstdio>
#include <exception>

int main() {
    bsa::BsaArchive a;
    try { a.open("fresh_nv_copy/Data/Fallout - Meshes.bsa"); }
    catch (const std::exception &e) { std::fprintf(stderr, "%s\n", e.what()); return 1; }
    const char *names[] = {"head\\headhuman", "head\\mouthhuman", "head\\teethlowerhuman", "head\\teethupperhuman", "head\\tonguehuman", "head\\eyelefthuman", "head\\eyerighthuman", "_male\\skeleton", "weapons\\1handpistol\\9mmpistol", "_male\\locomotion\\1hmright", "_male\\locomotion\\1hmleft", "_male\\locomotion\\2hhleft", "_male\\locomotion\\2hhright"};
    for (const char *n : names) {
        std::string p = std::string("meshes\\characters\\") + n + (std::string(n).find("locomotion") != std::string::npos ? ".kf" : ".nif");
        const auto *e = a.find(p);
        if (!e) { std::printf("%s missing\n", p.c_str()); continue; }
        try {
            auto m = nif::load_mesh(a.extract(*e));
            std::printf("%s submeshes=%zu skin=%zu scenes=%zu", p.c_str(), m.submeshes.size(), m.skin_data.size(), m.scene_nodes.size());
            if (std::string(n).find("skeleton") != std::string::npos) {
                for (const auto &scene : m.scene_nodes) std::printf(" [node=%s parent=%d]", scene.name.c_str(), scene.parent_index);
            }
            for (const auto &sequence : m.animation_sequences) {
                std::printf(" [seq=%s tracks=%zu", sequence.name.c_str(), sequence.tracks.size());
                for (const auto &track : sequence.tracks) std::printf(" %s", track.target_node_name.c_str());
                std::printf("]");
            }
            for (const auto &s : m.submeshes) std::printf(" [%s v=%zu t=(%.3f %.3f %.3f)]", s.name.c_str(), s.positions.size()/3, s.translation[0], s.translation[1], s.translation[2]);
            std::printf("\n");
        } catch (const std::exception &ex) { std::printf("%s ERROR %s\n", p.c_str(), ex.what()); }
    }
}
