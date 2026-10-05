# Class Rating and balance evidence

Overall Elo is unchanged. Max-level 60 class boards add a separate Class Rating, starting at 1,500 with K = 32. Leveling class boards use ordinary Elo. Other level caps do not inherit the level-60 matchup assumptions.

## Initial assumptions

The initial probabilities are **manual hypotheses for level 60**, not measured Forever win rates. Rows describe the chance of the row class beating the column class when their Class Ratings are equal.

| Class | Warrior | Paladin | Hunter | Rogue | Priest | Shaman | Mage | Warlock | Druid |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Warrior | 50 | 45 | 45 | 55 | 45 | 45 | 40 | 45 | 40 |
| Paladin | 55 | 50 | 50 | 55 | 45 | 50 | 45 | 40 | 50 |
| Hunter | 55 | 50 | 50 | 55 | 50 | 55 | 55 | 45 | 50 |
| Rogue | 45 | 45 | 45 | 50 | 50 | 55 | 50 | 45 | 40 |
| Priest | 55 | 55 | 50 | 50 | 50 | 55 | 55 | 45 | 55 |
| Shaman | 55 | 50 | 45 | 45 | 45 | 50 | 45 | 40 | 50 |
| Mage | 60 | 55 | 45 | 50 | 45 | 55 | 50 | 40 | 50 |
| Warlock | 55 | 60 | 55 | 55 | 55 | 60 | 60 | 50 | 55 |
| Druid | 60 | 50 | 50 | 60 | 45 | 50 | 50 | 45 | 50 |

For a matchup probability `q`, its Elo offset is `400 * log10(q / (1 - q))`. Expected winner probability is `1 / (1 + 10 ** (-(winnerClassRating - loserClassRating + offset) / 400))`. Both players receive complementary integer changes of `floor(32 * (1 - expectedWinner) + 0.5)`. Mirrors have zero offset. A Warrior at equal rating gains 19 for beating a Mage and loses 13 for losing to one.

The first immutable matrix applies to all confirmed history. Later approved versions have a documented effective timestamp. Replay sorts confirmed matches by end time and match ID and selects the version effective at that match's end time, including for late imports. Match projections retain the version and expected probability used. Overall and class histories remain separate.

## Evidence and limitations

The comparison groups are 1–9, 10–19, 20–29, 30–39, 40–49, 50–59 and maximum level 60. The overview includes all confirmed matches; calibration uses only equal-level matches in the same recorded ruleset and level cap. A repeated character pair contributes at most one unit per UTC day and five units per analysis window. Ordinary Leveling Elo is not used as an estimate of player ability.

The administrative Python tool jointly estimates character strength and antisymmetric matchup offsets with a regularized Bradley–Terry model. Offset priors use the active matrix with standard deviation 75 Elo; character strengths use standard deviation 400 Elo. Offsets are bounded to ±150 Elo. Strengths are centered to mean zero within each class and level group.

**Centering assumes comparably skilled average player populations.** Differences in player selection, gear or specialization can still appear as matchup effects. The result is evidence for reviewing an assumption, not proof of class balance. Current Blizzard profile data cannot reconstruct historical gear, specialization or a historical ruleset.

Only 50–59 can generate a Leveling-supported max-level proposal. Two consecutive 14-day windows must independently meet all defaults: 100 considered matches, 20 characters per class and 30 distinct character pairs. Both estimates must point in the same direction and both 95% intervals must exclude the active assumption. Intervals use 500 character-cluster bootstrap repetitions with a fixed random seed. Direct max-level evidence is shown separately; a contradictory signal blocks the Leveling proposal. Lower bands describe development and cannot trigger a change alone.

A proposed change moves toward the pooled estimate by at most five percentage points per pair and matrix version; the reverse direction is its complement. The next revision requires new validation windows after the preceding data cutoff. A proposal remains provisional, particularly without sufficient max-level data, and requires explicit administrative approval. Failed, undersized or contradictory analyses cannot change the active matrix.

The analysis runs outside HTTP requests and imports. Its dataset hash, cutoff, ruleset, baseline version, fit diagnostics, sample sizes and uncertainty are preserved with the report. Only aggregate comparison evidence is exposed publicly; offline exports contain character GUIDs and should be kept in the ignored `web/exports/` directory.

## Website and API

`GET /api/v1/ladder?ranking=OVERALL` preserves the Overall leaderboard. `ranking=CLASS&classFile=MAGE` selects a class leaderboard. The existing `rating` field always means Overall Elo; additional fields expose Class Rating, own-class rank, overall rank and model status. Ranks are computed before search, realm filtering and pagination. Leveling and unsupported-cap class boards clearly identify their ordinary Elo basis.

`GET /api/v1/class-comparisons` supplies the assumptions and aggregate evidence. English statuses distinguish **Manual baseline**, **Leveling evidence — provisional** and **Insufficient data**. Profiles display both rating histories where Class Rating is supported. Class selections are shareable in the URL and retain the existing light/dark themes and official icons.

## Local administration

The command workflow and exact analysis options are documented in [README.md](README.md). Publishing an analysis report and activating a matrix are separate administrator actions. The initial matrix is already authorized by the implementation plan; no later proposal is activated automatically.

Model reference: [Turner and Firth, Bradley–Terry Models in R](https://www.jstatsoft.org/article/view/v048i09). The repeat limits, sample thresholds, prior scales and five-point step are product defaults, not universal statistical guarantees.
