/// Backward-compat shim. The class previously known as
/// `ScrivenningsSession` was renamed to [MultiSectionEditingSession]
/// in P2 #8 (live page view) when the same session became the engine
/// for both Scrivenings and Page views. This file re-exports the new
/// name under the old alias so external test fixtures keep compiling.
library;

export 'package:inkspacex/services/multi_section_editing_session.dart';

import 'package:inkspacex/services/multi_section_editing_session.dart';

typedef ScrivenningsSession = MultiSectionEditingSession;
