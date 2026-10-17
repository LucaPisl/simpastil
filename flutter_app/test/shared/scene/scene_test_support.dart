import 'package:flutter/material.dart';
import 'package:simpastil/shared/scene/horizon_model.dart';
import 'package:simpastil/shared/scene/horizon_scene.dart';
import 'package:simpastil/shared/theme/app_theme.dart';

const sceneSize = Size(390, 170);

/// Late April: sunrise about 06:20, sunset about 20:05, waxing moon.
final sceneDate = DateTime(2026, 4, 26);

DateTime at(int h, int m) => DateTime(2026, 4, 26, h, m);

const phaseTimes = <String, (int, int)>{
  'dawn': (7, 0),
  'day': (12, 30),
  'dusk': (19, 30),
  'night': (23, 0),
};

const sampleDoses = <HorizonDose>[
  HorizonDose(
    id: 'a',
    plannedLocalTime: '08:00:00',
    state: 'taken',
    person: 'Ana',
  ),
  HorizonDose(
    id: 'b',
    plannedLocalTime: '08:00:00',
    state: 'taken',
    person: 'Mihai',
  ),
  HorizonDose(
    id: 'c',
    plannedLocalTime: '08:00:00',
    state: 'pending',
    person: 'Ana',
  ),
  HorizonDose(
    id: 'd',
    plannedLocalTime: '08:00:00',
    state: 'pending',
    person: 'Mihai',
  ),
  HorizonDose(
    id: 'e',
    plannedLocalTime: '13:00:00',
    state: 'taken',
    person: 'Ana',
  ),
  HorizonDose(
    id: 'f',
    plannedLocalTime: '13:00:00',
    state: 'pending',
    person: 'Mihai',
  ),
  HorizonDose(
    id: 'g',
    plannedLocalTime: '20:00:00',
    state: 'pending',
    person: 'Ana',
  ),
  HorizonDose(
    id: 'h',
    plannedLocalTime: '22:30:00',
    state: 'skipped',
    person: 'Ana',
  ),
  HorizonDose(id: 'p', plannedLocalTime: null, state: 'pending', person: 'Ana'),
];

HorizonModel modelFor(
  DateTime now,
  Brightness b, {
  bool highContrast = false,
  List<HorizonDose> doses = sampleDoses,
  DateTime? date,
  Size size = sceneSize,
}) => HorizonModel.compute(
  date: date ?? sceneDate,
  now: now,
  b: b,
  highContrast: highContrast,
  doses: doses,
  size: size,
);

ThemeData themeFor(Brightness b, {bool highContrast = false}) =>
    b == Brightness.light
    ? AppTheme.light(highContrast: highContrast)
    : AppTheme.dark(highContrast: highContrast);

Widget sceneOf(HorizonModel model, {String? celebrateId, String? sweepId}) =>
    SizedBox.fromSize(
      size: model.size,
      child: HorizonScene(
        model: model,
        semanticsLabel: 'Day sky',
        celebrateId: celebrateId,
        sweepId: sweepId,
      ),
    );
