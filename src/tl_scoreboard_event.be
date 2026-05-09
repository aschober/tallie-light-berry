#@ solidify:TLScoreboardEvent,weak
class TLScoreboardEvent
  var competitor_abbreviation
  var competitor_slug
  var competitor_winner
  var competitor_score
  var competitor_home_away
  var opponent_abbreviation
  var opponent_winner
  var opponent_score
  var competition_date
  var competition_status_short_detail
  var competition_status_state
  var league_short_display_name
  var last_updated

  def init(event)
    var competitor = event['competitor']
    self.competitor_abbreviation = competitor['abbreviation']
    self.competitor_slug = competitor['slug']
    self.competitor_winner = competitor.find('winner', nil)
    self.competitor_score = competitor['score']
    self.competitor_home_away = (competitor.find('homeAway', '') == 'home')

    var opponent = event['opponent']
    self.opponent_abbreviation = opponent['abbreviation']
    self.opponent_winner = opponent.find('winner', nil)
    self.opponent_score = opponent['score']

    var competition = event['competition']
    self.competition_date = tasmota.strptime(competition['date'], '%Y-%m-%dT%H:%MZ')

    var status_type = competition['status']['type']
    self.competition_status_short_detail = status_type['shortDetail']
    self.competition_status_state = status_type.find('state', nil)
    self.league_short_display_name = competition.find('leagueShortDisplayName', nil)

    self.last_updated = event.find('lastUpdated', tasmota.rtc()['utc'])
  end

  def is_scheduled()    return (self.competition_status_state == 'pre') end
  def is_final()        return (self.competition_status_state == 'post') end
  def is_in_progress()  return (self.competition_status_state == 'in') end
  def is_winner()
    return self.is_final() && self.competitor_winner == true
  end
  def is_winning()
    return self.is_winner() || (self.is_in_progress() && self.competitor_score > self.opponent_score)
  end

  def tostring()
    return format('TLScoreboardEvent(%s vs %s, %s (%s), %s-%s, %d)',
      self.competitor_abbreviation, self.opponent_abbreviation,
      self.competition_status_short_detail, self.competition_status_state,
      self.competitor_score, self.opponent_score, self.last_updated)
  end
end
global.TLScoreboardEvent = TLScoreboardEvent
