/// Types de manœuvres stockés dans `Maneuver.type` (libellés stables,
/// indépendants du moteur d'itinéraire).
class ManeuverKind {
  ManeuverKind._();

  static const depart = 'depart';
  static const arrive = 'arrive';
  static const waypoint = 'waypoint';
  static const straight = 'straight';
  static const continueOn = 'continue';
  static const becomes = 'becomes';
  static const slightRight = 'slight_right';
  static const right = 'right';
  static const sharpRight = 'sharp_right';
  static const uturnRight = 'uturn_right';
  static const uturnLeft = 'uturn_left';
  static const sharpLeft = 'sharp_left';
  static const left = 'left';
  static const slightLeft = 'slight_left';
  static const rampStraight = 'ramp_straight';
  static const rampRight = 'ramp_right';
  static const rampLeft = 'ramp_left';
  static const exitRight = 'exit_right';
  static const exitLeft = 'exit_left';
  static const stayStraight = 'stay_straight';
  static const stayRight = 'stay_right';
  static const stayLeft = 'stay_left';
  static const merge = 'merge';
  static const mergeRight = 'merge_right';
  static const mergeLeft = 'merge_left';
  static const roundabout = 'roundabout';
  static const roundaboutExit = 'roundabout_exit';
  static const ferry = 'ferry';
  static const ferryExit = 'ferry_exit';
  static const other = 'other';

  /// Codes numériques Valhalla (`maneuvers[].type`) → libellés.
  static String fromValhalla(int code) => switch (code) {
    1 || 2 || 3 => depart,
    4 || 5 || 6 => arrive,
    7 => becomes,
    8 => continueOn,
    9 => slightRight,
    10 => right,
    11 => sharpRight,
    12 => uturnRight,
    13 => uturnLeft,
    14 => sharpLeft,
    15 => left,
    16 => slightLeft,
    17 => rampStraight,
    18 => rampRight,
    19 => rampLeft,
    20 => exitRight,
    21 => exitLeft,
    22 => stayStraight,
    23 => stayRight,
    24 => stayLeft,
    25 => merge,
    26 => roundabout,
    27 => roundaboutExit,
    28 => ferry,
    29 => ferryExit,
    37 => mergeRight,
    38 => mergeLeft,
    _ => other,
  };

  /// Manœuvres « passives » qui ne demandent pas d'action particulière.
  static bool isPassive(String kind) =>
      kind == continueOn || kind == becomes || kind == straight || kind == stayStraight || kind == depart;
}
