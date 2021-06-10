from common.redis import generalPubSubHandler
from objects import glob

class handler(generalPubSubHandler.generalPubSubHandler):
	def __init__(self):
		super().__init__()
		self.structure = {"user_id": 999}
		self.strict = False

	def handle(self, data):
		data = super().parseData(data)
		if data is None: return
		glob.clan_cache.cache_individual(data["user_id"])
