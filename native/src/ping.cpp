#include "ping.h"

using namespace godot;

void NVPing::_bind_methods() {
	ClassDB::bind_method(D_METHOD("ping"), &NVPing::ping);
}

String NVPing::ping() const {
	return "nv-engine-native-ok";
}
