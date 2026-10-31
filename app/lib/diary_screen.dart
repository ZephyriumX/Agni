import 'package:flutter/material.dart';
import 'api.dart';

/// PRD F8 Food Compatibility Diary: meals ranked by how little autonomic stress they caused.
class DiaryScreen extends StatelessWidget {
  const DiaryScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Food diary')),
      body: FutureBuilder<Map<String, dynamic>>(
        future: Api.diary(),
        builder: (c, s) {
          if (s.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
          if (s.hasError) return Padding(padding: const EdgeInsets.all(16), child: SelectableText('${s.error}'));
          final ranked = List<Map<String, dynamic>>.from((s.data!['ranked'] ?? []).map((e) => Map<String, dynamic>.from(e)));
          final pending = List<Map<String, dynamic>>.from((s.data!['pending'] ?? []).map((e) => Map<String, dynamic>.from(e)));
          if (ranked.isEmpty && pending.isEmpty) {
            return const Padding(padding: EdgeInsets.all(16), child: Text('Log a meal by choosing "Post-Meal" on the scan screen and typing what you ate.'));
          }
          return ListView(padding: const EdgeInsets.all(16), children: [
            for (final r in ranked)
              ListTile(
                leading: CircleAvatar(child: Text('${(r['compatibility_pct'] as num).round()}')),
                title: Text(r['name']),
                subtitle: Text('${r['verdict']}  ·  HRV ratio ${(r['hrv_ratio'] as num).toStringAsFixed(2)}'),
              ),
            if (pending.isNotEmpty) const Divider(),
            for (final r in pending) ListTile(title: Text(r['name']), subtitle: const Text('waiting for a good-quality post-meal scan')),
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text('Compatibility % = 100 × RMSSD(post)/RMSSD(baseline), capped at 100; below 70 = "Incompatible" (PRD threshold). Wellness estimate only.',
                  style: TextStyle(fontSize: 11, color: Colors.grey)),
            ),
          ]);
        },
      ),
    );
  }
}
