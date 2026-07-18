const app = angular.module('catsvsdogs', []);

// Decide which namespace to use, but always use the /result/socket.io path
let namespace = '/'; // default namespace
if (window.location.pathname.startsWith('/result')) {
  namespace = '/result';  // /result namespace
}

// Connect using the chosen namespace, but ALWAYS path: '/result/socket.io'
const socket = io(namespace, {
  path: '/result/socket.io',
  transports: ['websocket', 'polling']
});

const bg1 = document.getElementById('background-stats-1');
const bg2 = document.getElementById('background-stats-2');

app.controller('statsCtrl', function($scope) {
  $scope.aPercent = 50;
  $scope.bPercent = 50;

  const updateScores = function() {
    socket.on('scores', function (json) {
      const data = JSON.parse(json);
      const a = Number.parseInt(data.a || 0, 10);
      const b = Number.parseInt(data.b || 0, 10);

      const percentages = getPercentages(a, b);
      bg1.style.width = percentages.a + "%";
      bg2.style.width = percentages.b + "%";

      $scope.$apply(function () {
        $scope.aPercent = percentages.a;
        $scope.bPercent = percentages.b;
        $scope.total = a + b;
      });
    });
  };

  const init = function() {
    document.body.style.opacity = 1;
    updateScores();
  };

  // "message" is just an example event to signal readiness
  socket.on('message', function(data) {
    init();
  });
});

function getPercentages(a, b) {
  const total = a + b;
  if (total > 0) {
    const percA = (a / total) * 100;
    const percB = (b / total) * 100;
    return { a: percA, b: percB };
  }
  return { a: 50, b: 50 };
}
